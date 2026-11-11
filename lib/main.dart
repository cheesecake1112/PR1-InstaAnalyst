import 'dart:async';
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

void main() => runApp(const InstaAnalystApp());

const violet = Color(0xFF7657F6);
const canvas = Color(0xFFF7F6FA);

Color _primaryText(BuildContext context) =>
    Theme.of(context).colorScheme.onSurface;
Color _secondaryText(BuildContext context) =>
    Theme.of(context).colorScheme.onSurfaceVariant;
Color _surface(BuildContext context) => Theme.of(context).colorScheme.surface;
Color _surfaceBorder(BuildContext context) =>
    Theme.of(context).colorScheme.outlineVariant;

String _cleanUsername(String value) => value
    .trim()
    .replaceFirst(RegExp(r'^@'), '')
    .replaceAll(RegExp(r'^https?://(?:www\.)?instagram\.com/'), '')
    .replaceAll(RegExp(r'/$'), '')
    .trim()
    .toLowerCase();

String? _usernameFromProfileUrl(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      !{'instagram.com', 'www.instagram.com'}.contains(uri.host.toLowerCase()))
    return null;
  final parts = uri.pathSegments.where((part) => part.isNotEmpty).toList();
  if (parts.isEmpty) return null;
  final username = parts.first == '_u' && parts.length > 1
      ? parts[1]
      : parts.first;
  return _cleanUsername(username);
}

Map<String, int> _parseAccountRecords(String source) {
  final text = source.trim();
  if (text.isEmpty) return {};
  final found = <String, int>{};
  void add(String? rawName, int? timestamp) {
    if (rawName == null || rawName.trim().isEmpty) return;
    final username =
        _usernameFromProfileUrl(rawName) ?? _cleanUsername(rawName);
    if (username.isEmpty) return;
    if (timestamp != null && timestamp > 0) {
      found[username] = timestamp;
    } else {
      found.putIfAbsent(username, () => 0);
    }
  }

  int? readTimestamp(dynamic value) {
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  try {
    final decoded = jsonDecode(text);
    void visit(dynamic value) {
      if (value is Map) {
        final recordTimestamp = readTimestamp(value['timestamp']);
        final title = value['title'];
        if (title is String && title.trim().isNotEmpty)
          add(title, recordTimestamp);
        final stringList = value['string_list_data'];
        if (stringList is List) {
          for (final entry in stringList) {
            if (entry is! Map) continue;
            final username = entry['value'] is String
                ? entry['value'] as String
                : entry['href'] as String?;
            add(username, readTimestamp(entry['timestamp']) ?? recordTimestamp);
          }
        }
        final labelValues = value['label_values'];
        if (labelValues is List) {
          for (final field in labelValues) {
            if (field is! Map || field['value'] is! String) continue;
            final fieldValue = field['value'] as String;
            final label = field['label']?.toString().toLowerCase() ?? '';
            final profileUsername = _usernameFromProfileUrl(fieldValue);
            if (profileUsername != null) {
              add(profileUsername, recordTimestamp);
            } else if (label.contains('username') ||
                label == 'user name' ||
                label == 'handle') {
              add(fieldValue, recordTimestamp);
            }
          }
        }
        for (final entry in value.entries) {
          if (entry.key != 'string_list_data' && entry.key != 'label_values')
            visit(entry.value);
        }
      } else if (value is List) {
        for (final item in value) {
          visit(item);
        }
      }
    }

    visit(decoded);
    return found;
  } catch (_) {
    final htmlPattern = RegExp(
      r'''href\s*=\s*["'](?:https?://)?(?:www\.)?instagram\.com/([^/"'?#]+)''',
      caseSensitive: false,
    );
    for (final match in htmlPattern.allMatches(text)) {
      add('https://www.instagram.com/${match.group(1)!}', null);
    }
    if (found.isNotEmpty) return found;
    for (final line in text.split(RegExp(r'[\r\n,\s]+'))) {
      add(line, null);
    }
    return found;
  }
}

Map<String, dynamic> _buildComparisonLists(
  Map<String, int> followerRecords,
  Map<String, int> followingRecords, [
  Set<String> closeFriendValues = const <String>{},
  Set<String> blockedAccountValues = const <String>{},
]) {
  final followers = followerRecords.keys.toSet();
  final following = followingRecords.keys.toSet();
  final closeFriends = closeFriendValues.toSet();
  final blockedAccounts = blockedAccountValues.toSet();
  List<String> sorted(Iterable<String> users) => users.toList()..sort();
  return {
    'followers': sorted(followers),
    'following': sorted(following),
    'notFollowingBack': sorted(following.difference(followers)),
    'notFollowedBack': sorted(followers.difference(following)),
    'mutuals': sorted(followers.intersection(following)),
    'closeFriends': sorted(closeFriends),
    'closeFriendsNotFollowingBack': sorted(closeFriends.difference(followers)),
    'blockedAccounts': sorted(blockedAccounts),
    'all': sorted({...followers, ...following, ...blockedAccounts}),
    'followerTimestamps': Map<String, int>.fromEntries(
      followerRecords.entries.where((entry) => entry.value > 0),
    ),
    'followingTimestamps': Map<String, int>.fromEntries(
      followingRecords.entries.where((entry) => entry.value > 0),
    ),
  };
}

Map<String, dynamic> _parsePastedPair(List<String> sources) =>
    _buildComparisonLists(
      _parseAccountRecords(sources[0]),
      _parseAccountRecords(sources[1]),
    );

Map<String, dynamic> _parseExportZip(List<int> bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);
  final followerRecords = <String, int>{};
  final followingRecords = <String, int>{};
  final closeFriends = <String>{};
  final blockedAccounts = <String>{};
  final followerFilePattern = RegExp(
    r'^followers(?:_\d+)?\.(?:json|html?)$',
    caseSensitive: false,
  );
  final followingFilePattern = RegExp(
    r'^following(?:_\d+)?\.(?:json|html?)$',
    caseSensitive: false,
  );
  final closeFriendsFilePattern = RegExp(
    r'^close_friends\.(?:json|html?)$',
    caseSensitive: false,
  );
  final blockedFilePattern = RegExp(
    r'^blocked_(?:profiles|accounts)\.(?:json|html?)$',
    caseSensitive: false,
  );
  for (final entry in archive) {
    if (!entry.isFile) continue;
    final basename = entry.name.replaceAll('\\', '/').split('/').last;
    if (!followerFilePattern.hasMatch(basename) &&
        !followingFilePattern.hasMatch(basename) &&
        !closeFriendsFilePattern.hasMatch(basename) &&
        !blockedFilePattern.hasMatch(basename))
      continue;
    final content = utf8.decode(
      entry.content as List<int>,
      allowMalformed: true,
    );
    if (followerFilePattern.hasMatch(basename)) {
      followerRecords.addAll(_parseAccountRecords(content));
    } else if (followingFilePattern.hasMatch(basename)) {
      followingRecords.addAll(_parseAccountRecords(content));
    } else if (closeFriendsFilePattern.hasMatch(basename)) {
      closeFriends.addAll(_parseAccountRecords(content).keys);
    } else {
      blockedAccounts.addAll(_parseAccountRecords(content).keys);
    }
  }
  return _buildComparisonLists(
    followerRecords,
    followingRecords,
    closeFriends,
    blockedAccounts,
  );
}

String _encodeSourceLists(Map<String, dynamic> sources) => jsonEncode(sources);

List<String> _filterUserList(List<dynamic> arguments) {
  final users = (arguments[0] as List<dynamic>).cast<String>();
  final needle = arguments[1] as String;
  return users.where((user) => user.toLowerCase().contains(needle)).toList();
}

Map<String, dynamic> _decodeSavedLists(String encoded) {
  final saved = jsonDecode(encoded) as Map<String, dynamic>;
  final savedFollowers =
      (saved['followers'] as List<dynamic>? ?? const <dynamic>[])
          .whereType<String>()
          .toList();
  final savedFollowing =
      (saved['following'] as List<dynamic>? ?? const <dynamic>[])
          .whereType<String>()
          .toList();
  final savedCloseFriends =
      (saved['closeFriends'] as List<dynamic>? ?? const <dynamic>[])
          .whereType<String>()
          .toSet();
  final savedBlockedAccounts =
      (saved['blockedAccounts'] as List<dynamic>? ?? const <dynamic>[])
          .whereType<String>()
          .toSet();
  final followerTimestamps = _readTimestampMap(saved['followerTimestamps']);
  final followingTimestamps = _readTimestampMap(saved['followingTimestamps']);
  return _buildComparisonLists(
    Map.fromEntries(
      savedFollowers.map(
        (username) => MapEntry(username, followerTimestamps[username] ?? 0),
      ),
    ),
    Map.fromEntries(
      savedFollowing.map(
        (username) => MapEntry(username, followingTimestamps[username] ?? 0),
      ),
    ),
    savedCloseFriends,
    savedBlockedAccounts,
  );
}

Map<String, int> _readTimestampMap(dynamic value) {
  if (value is! Map) return {};
  return value.map(
    (key, timestamp) =>
        MapEntry(key.toString(), timestamp is num ? timestamp.toInt() : 0),
  );
}

class InstaAnalystApp extends StatefulWidget {
  const InstaAnalystApp({super.key});

  @override
  State<InstaAnalystApp> createState() => _InstaAnalystAppState();
}

class _InstaAnalystAppState extends State<InstaAnalystApp> {
  ThemeMode _themeMode = ThemeMode.system;

  @override
  void initState() {
    super.initState();
    _loadThemeMode();
  }

  Future<void> _loadThemeMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedMode = prefs.getString('socialscope.themeMode.v1');
      final restoredMode = ThemeMode.values.firstWhere(
        (mode) => mode.name == savedMode,
        orElse: () => ThemeMode.system,
      );
      if (mounted) setState(() => _themeMode = restoredMode);
    } catch (_) {
      // Keep following the device theme when preferences are unavailable.
    }
  }

  Future<void> _setThemeMode(ThemeMode mode) async {
    setState(() => _themeMode = mode);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('socialscope.themeMode.v1', mode.name);
    } catch (_) {
      // The current selection remains active for this app session.
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'SocialScope',
    theme: ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: canvas,
      colorScheme: ColorScheme.fromSeed(
        seedColor: violet,
        brightness: Brightness.light,
      ),
      fontFamily: 'Roboto',
    ),
    darkTheme: ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: const Color(0xFF11101A),
      colorScheme:
          ColorScheme.fromSeed(
            seedColor: violet,
            brightness: Brightness.dark,
          ).copyWith(
            surface: const Color(0xFF1B1925),
            onSurface: const Color(0xFFF2F0F8),
            onSurfaceVariant: const Color(0xFFB2ADBF),
            outlineVariant: const Color(0xFF393644),
          ),
      fontFamily: 'Roboto',
    ),
    themeMode: _themeMode,
    home: DashboardPage(
      themeMode: _themeMode,
      onThemeModeChanged: _setThemeMode,
    ),
  );
}

class DashboardPage extends StatefulWidget {
  const DashboardPage({
    super.key,
    required this.themeMode,
    required this.onThemeModeChanged,
  });
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;
  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  Set<String> followers = {};
  Set<String> following = {};
  Set<String> notFollowingBack = {};
  Set<String> notFollowedBack = {};
  Set<String> mutuals = {};
  Set<String> closeFriends = {};
  Set<String> closeFriendsNotFollowingBack = {};
  Set<String> blockedAccounts = {};
  final Set<String> visitedProfiles = {};
  final Set<String> notFoundAccounts = {};
  final Set<String> selectedReviewAccounts = {};
  Map<String, dynamic> _lists = const {};
  Map<String, int> followerTimestamps = const {};
  Map<String, int> followingTimestamps = const {};
  List<String> _visibleUsers = const [];
  int activePage = 0;
  int selectedTab = 0;
  int sortMode = 0;
  int defaultTab = 0;
  int defaultSortMode = 0;
  String followDateDisplay = 'days';
  int _filterRequest = 0;
  String query = '';
  bool restoringData = true;
  DateTime? lastImportAt;
  Timer? _queryDebounce;
  bool get hasData =>
      _lists['followers']?.isNotEmpty == true ||
      _lists['following']?.isNotEmpty == true;

  List<String> _strings(Map<String, dynamic> lists, String key) {
    final value = lists[key];
    return value is List
        ? value.whereType<String>().toList()
        : const <String>[];
  }

  void _applyLists(Map<String, dynamic> lists, {bool clearVisited = true}) {
    _lists = lists;
    followers = _strings(lists, 'followers').toSet();
    following = _strings(lists, 'following').toSet();
    notFollowingBack = _strings(lists, 'notFollowingBack').toSet();
    notFollowedBack = _strings(lists, 'notFollowedBack').toSet();
    mutuals = _strings(lists, 'mutuals').toSet();
    closeFriends = _strings(lists, 'closeFriends').toSet();
    closeFriendsNotFollowingBack = _strings(
      lists,
      'closeFriendsNotFollowingBack',
    ).toSet();
    blockedAccounts = _strings(lists, 'blockedAccounts').toSet();
    _visibleUsers = _strings(lists, 'all');
    followerTimestamps = _readTimestampMap(lists['followerTimestamps']);
    followingTimestamps = _readTimestampMap(lists['followingTimestamps']);
    if (clearVisited) visitedProfiles.clear();
  }

  @override
  void initState() {
    super.initState();
    _restoreSavedData();
  }

  Future<void> _restoreSavedData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = prefs.getString('socialscope.data.v1');
      final savedVisited =
          prefs.getStringList('socialscope.visited.v1') ?? const <String>[];
      final savedNotFound =
          prefs.getStringList('socialscope.notFound.v1') ?? const <String>[];
      final savedImportMillis = prefs.getInt('socialscope.lastImportAt.v1');
      final savedTab = prefs.getInt('socialscope.defaultTab.v1') ?? 0;
      final savedSort = prefs.getInt('socialscope.defaultSort.v1') ?? 0;
      final savedDateDisplay =
          prefs.getString('socialscope.followDateDisplay.v1') ?? 'days';
      final lists = encoded == null
          ? _buildComparisonLists(const <String, int>{}, const <String, int>{})
          : await compute(_decodeSavedLists, encoded);
      if (!mounted) return;
      setState(() {
        _applyLists(lists, clearVisited: false);
        defaultTab = savedTab.clamp(0, 9);
        defaultSortMode = savedSort.clamp(0, 5);
        sortMode = defaultSortMode;
        followDateDisplay =
            const {'days', 'date', 'hidden'}.contains(savedDateDisplay)
            ? savedDateDisplay
            : 'days';
        selectedTab = defaultTab;
        visitedProfiles.addAll(savedVisited);
        notFoundAccounts
          ..clear()
          ..addAll(savedNotFound.map((username) => username.toLowerCase()));
        _visibleUsers = _sortUsers(_listForTab(selectedTab));
        lastImportAt = savedImportMillis == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(savedImportMillis);
        restoringData = false;
      });
    } catch (_) {
      if (mounted) setState(() => restoringData = false);
    }
  }

  Future<void> _saveData(_ImportResult result, DateTime importedAt) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = await compute(_encodeSourceLists, {
      'followers': result.lists['followers'] ?? const <String>[],
      'following': result.lists['following'] ?? const <String>[],
      'closeFriends': result.lists['closeFriends'] ?? const <String>[],
      'blockedAccounts': result.lists['blockedAccounts'] ?? const <String>[],
      'followerTimestamps':
          result.lists['followerTimestamps'] ?? const <String, int>{},
      'followingTimestamps':
          result.lists['followingTimestamps'] ?? const <String, int>{},
    });
    await prefs.setString('socialscope.data.v1', encoded);
    await prefs.setStringList('socialscope.visited.v1', const <String>[]);
    await prefs.setStringList('socialscope.notFound.v1', const <String>[]);
    await prefs.setInt(
      'socialscope.lastImportAt.v1',
      importedAt.millisecondsSinceEpoch,
    );
  }

  Future<void> _saveVisitedProfiles() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        'socialscope.visited.v1',
        visitedProfiles.toList()..sort(),
      );
    } catch (_) {
      // The current-session highlight still works if persistence is unavailable.
    }
  }

  Future<void> _clearSavedData() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear saved data?'),
        content: const Text(
          'This removes your imported lists, last upload time, opened-profile marks, and Not found list from this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFB64242),
            ),
            child: const Text('Clear data'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('socialscope.data.v1');
      await prefs.remove('socialscope.visited.v1');
      await prefs.remove('socialscope.notFound.v1');
      await prefs.remove('socialscope.lastImportAt.v1');
      if (!mounted) return;
      setState(() {
        _applyLists(
          _buildComparisonLists(const <String, int>{}, const <String, int>{}),
        );
        visitedProfiles.clear();
        notFoundAccounts.clear();
        lastImportAt = null;
        selectedTab = 0;
        query = '';
        activePage = 0;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saved data cleared from this device.')),
      );
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not clear all saved data. Please try again.'),
          ),
        );
    }
  }

  Future<void> _exportLocalBackup() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = prefs.getString('socialscope.data.v1');
      if (data == null) {
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Import Instagram data before creating a backup.'),
            ),
          );
        return;
      }
      final backup = jsonEncode({
        'format': 'socialscope-backup',
        'version': 1,
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'data': data,
        'visitedProfiles': visitedProfiles.toList()..sort(),
        'notFoundAccounts': notFoundAccounts.toList()..sort(),
        'lastImportAt': prefs.getInt('socialscope.lastImportAt.v1'),
      });
      final file = await FilePicker.saveFile(
        dialogTitle: 'Save SocialScope backup',
        fileName: 'socialscope-backup.json',
        bytes: Uint8List.fromList(utf8.encode(backup)),
      );
      if (file != null && mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Local backup saved.')));
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not save the backup. Please try again.'),
          ),
        );
    }
  }

  Future<void> _restoreLocalBackup() async {
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: const ['json'],
      );
      if (file == null) return;
      final backup = jsonDecode(
        utf8.decode(await file.readAsBytes()),
      ) as Map<String, dynamic>;
      if (backup['format'] != 'socialscope-backup' ||
          backup['version'] != 1 ||
          backup['data'] is! String) {
        throw const FormatException('Invalid SocialScope backup');
      }
      final encoded = backup['data'] as String;
      final lists = await compute(_decodeSavedLists, encoded);
      final savedVisited =
          (backup['visitedProfiles'] as List<dynamic>? ?? const <dynamic>[])
              .whereType<String>()
              .toSet();
      final savedNotFound =
          (backup['notFoundAccounts'] as List<dynamic>? ?? const <dynamic>[])
              .whereType<String>()
              .map((username) => username.toLowerCase())
              .toSet();
      final savedImportMillis = backup['lastImportAt'] is num
          ? (backup['lastImportAt'] as num).toInt()
          : null;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('socialscope.data.v1', encoded);
      await prefs.setStringList(
        'socialscope.visited.v1',
        savedVisited.toList()..sort(),
      );
      await prefs.setStringList(
        'socialscope.notFound.v1',
        savedNotFound.toList()..sort(),
      );
      if (savedImportMillis == null) {
        await prefs.remove('socialscope.lastImportAt.v1');
      } else {
        await prefs.setInt('socialscope.lastImportAt.v1', savedImportMillis);
      }
      if (!mounted) return;
      _queryDebounce?.cancel();
      _filterRequest++;
      setState(() {
        _applyLists(lists);
        visitedProfiles
          ..clear()
          ..addAll(savedVisited);
        notFoundAccounts
          ..clear()
          ..addAll(savedNotFound);
        lastImportAt = savedImportMillis == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(savedImportMillis);
        selectedTab = 0;
        _visibleUsers = _sortUsers(_listForTab(selectedTab));
        query = '';
        activePage = 0;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Local backup restored.')));
    } on FormatException catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('That file is not a valid SocialScope backup.'),
          ),
        );
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not restore this backup. Please check the file and try again.',
            ),
          ),
        );
    }
  }

  List<String> _listForTab(int tab) {
    if (tab == 9) return notFoundAccounts.toList()..sort();
    return _strings(_lists, switch (tab) {
          1 => 'followers',
          2 => 'following',
          3 => 'notFollowingBack',
          4 => 'notFollowedBack',
          5 => 'mutuals',
          6 => 'closeFriends',
          7 => 'closeFriendsNotFollowingBack',
          8 => 'blockedAccounts',
          _ => 'all',
        })
        .where((username) => !notFoundAccounts.contains(username.toLowerCase()))
        .toList();
  }

  int _visibleCount(Iterable<String> usernames) => usernames
      .where((username) => !notFoundAccounts.contains(username.toLowerCase()))
      .length;

  List<String> _sortUsers(List<String> users) {
    final sorted = List<String>.of(users);
    sorted.sort((left, right) {
      final leftOpened = visitedProfiles.contains(left.toLowerCase());
      final rightOpened = visitedProfiles.contains(right.toLowerCase());
      if (leftOpened != rightOpened) return leftOpened ? 1 : -1;
      if (sortMode == 0 || sortMode == 1) {
        final comparison = left.toLowerCase().compareTo(right.toLowerCase());
        return sortMode == 0 ? comparison : -comparison;
      }
      final timestamps = sortMode == 2 || sortMode == 3
          ? followerTimestamps
          : followingTimestamps;
      final leftTimestamp = timestamps[left];
      final rightTimestamp = timestamps[right];
      if (leftTimestamp == null && rightTimestamp != null) return 1;
      if (leftTimestamp != null && rightTimestamp == null) return -1;
      if (leftTimestamp == null && rightTimestamp == null) {
        return left.toLowerCase().compareTo(right.toLowerCase());
      }
      final comparison = leftTimestamp!.compareTo(rightTimestamp!);
      return sortMode == 2 || sortMode == 4 ? comparison : -comparison;
    });
    return sorted;
  }

  void _setSortMode(int mode) {
    setState(() {
      sortMode = mode;
      _visibleUsers = _sortUsers(_visibleUsers);
    });
  }

  void _selectList(int tab) {
    _queryDebounce?.cancel();
    _filterRequest++;
    setState(() {
      activePage = 1;
      selectedTab = tab;
      selectedReviewAccounts.clear();
      query = '';
      _visibleUsers = _sortUsers(_listForTab(tab));
    });
  }

  Future<void> _setDefaultTab(int tab) async {
    setState(() => defaultTab = tab);
    try {
      await (await SharedPreferences.getInstance()).setInt(
        'socialscope.defaultTab.v1',
        tab,
      );
    } catch (_) {}
  }

  Future<void> _toggleNotFoundAccount(String username) async {
    final normalized = username.toLowerCase();
    await _setNotFoundAccount(username, !notFoundAccounts.contains(normalized));
  }

  Future<void> _setNotFoundAccount(String username, bool marked) async {
    final normalized = username.toLowerCase();
    setState(() {
      if (marked) {
        notFoundAccounts.add(normalized);
      } else {
        notFoundAccounts.remove(normalized);
      }
      final needle = query.trim().toLowerCase();
      _visibleUsers = _sortUsers(
        _listForTab(selectedTab).where((account) {
          return needle.isEmpty || account.toLowerCase().contains(needle);
        }).toList(),
      );
    });
    try {
      await (await SharedPreferences.getInstance()).setStringList(
        'socialscope.notFound.v1',
        notFoundAccounts.toList()..sort(),
      );
    } catch (_) {}
  }

  Future<void> _setDefaultSortMode(int mode) async {
    setState(() => defaultSortMode = mode);
    try {
      await (await SharedPreferences.getInstance()).setInt(
        'socialscope.defaultSort.v1',
        mode,
      );
    } catch (_) {}
  }

  Future<void> _setFollowDateDisplay(String value) async {
    setState(() => followDateDisplay = value);
    try {
      await (await SharedPreferences.getInstance()).setString(
        'socialscope.followDateDisplay.v1',
        value,
      );
    } catch (_) {}
  }

  void _selectPage(int page) => setState(() => activePage = page);

  void _onQueryChanged(String value) {
    _queryDebounce?.cancel();
    _queryDebounce = Timer(const Duration(milliseconds: 180), () async {
      final tab = selectedTab;
      final request = ++_filterRequest;
      final needle = value.trim().toLowerCase();
      final users = needle.isEmpty
          ? _listForTab(tab)
          : await compute(_filterUserList, [_listForTab(tab), needle]);
      if (mounted && request == _filterRequest && tab == selectedTab) {
        setState(() {
          query = value;
          _visibleUsers = _sortUsers(users);
        });
      }
    });
  }

  @override
  void dispose() {
    _queryDebounce?.cancel();
    super.dispose();
  }

  Future<void> _openImport() async {
    if (restoringData) return;
    final result = await showDialog<_ImportResult>(
      context: context,
      builder: (_) => const ImportDialog(),
    );
    if (result == null) return;
    final importedAt = DateTime.now();
    try {
      await _saveData(result, importedAt);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not save this import on your device. Your previous results are still available.',
            ),
          ),
        );
      }
      return;
    }
    _queryDebounce?.cancel();
    _filterRequest++;
    setState(() {
      notFoundAccounts.clear();
      _applyLists(result.lists);
      selectedTab = 0;
      _visibleUsers = _sortUsers(_listForTab(selectedTab));
      selectedReviewAccounts.clear();
      query = '';
      lastImportAt = importedAt;
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Imported ${followers.length} followers and ${following.length} following. Previous Not found marks were cleared.',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _openInstagramProfile(String username) async {
    final cleanUsername = username.replaceAll('@', '');
    final normalized = cleanUsername.toLowerCase();
    final newlyOpened = visitedProfiles.add(normalized);
    final wasSelected = selectedReviewAccounts.remove(username);
    if (newlyOpened || wasSelected) {
      setState(() {
        _visibleUsers = _sortUsers(_visibleUsers);
      });
    }
    if (newlyOpened) {
      unawaited(_saveVisitedProfiles());
    }
    final appProfile = Uri(
      scheme: 'instagram',
      host: 'user',
      queryParameters: {'username': cleanUsername},
    );
    final webProfile = Uri.https('www.instagram.com', '/$cleanUsername/');
    var opened = false;
    try {
      opened = await launchUrl(
        appProfile,
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      // The Instagram app may not be installed or may not support this URI.
    }
    if (!opened) {
      try {
        opened = await launchUrl(
          webProfile,
          mode: LaunchMode.externalApplication,
        );
      } catch (_) {
        // Show the message below if the browser also cannot open the profile.
      }
    }
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open Instagram.')),
      );
    }
  }

  Future<void> _openSelectedReviewQueue() async {
    final queue = _visibleUsers.where(selectedReviewAccounts.contains).toList();
    if (queue.isEmpty) return;
    selectedReviewAccounts.clear();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => _ReviewQueueDialog(
        accounts: queue,
        notFoundAccounts: notFoundAccounts,
        onOpen: _openInstagramProfile,
        onSetNotFound: _setNotFoundAccount,
      ),
    );
    if (mounted) setState(() {});
  }

  void _toggleReviewAccount(String username, bool selected) {
    if (selected && visitedProfiles.contains(username.toLowerCase())) return;
    setState(() {
      if (selected) {
        selectedReviewAccounts.add(username);
      } else {
        selectedReviewAccounts.remove(username);
      }
    });
  }

  void _toggleAllVisibleReviewAccounts() {
    setState(() {
      final unopenedUsers = _visibleUsers
          .where((user) => !visitedProfiles.contains(user.toLowerCase()))
          .toList();
      final allVisibleSelected =
          unopenedUsers.isNotEmpty &&
          unopenedUsers.every(selectedReviewAccounts.contains);
      if (allVisibleSelected) {
        selectedReviewAccounts.removeAll(unopenedUsers);
      } else {
        selectedReviewAccounts.addAll(unopenedUsers);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final compact = width < 760;
    final users = _visibleUsers;
    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            if (!compact)
              _Sidebar(
                selectedPage: activePage,
                onSelect: _selectPage,
                onImport: _openImport,
              ),
            Expanded(
              child: Column(
                children: [
                  _TopBar(compact: compact, lastImportAt: lastImportAt),
                  Expanded(
                    child: restoringData
                        ? const Center(
                            child: CircularProgressIndicator(color: violet),
                          )
                        : CustomScrollView(
                            slivers: [
                              SliverPadding(
                                padding: EdgeInsets.fromLTRB(
                                  compact ? 20 : 42,
                                  28,
                                  compact ? 20 : 42,
                                  0,
                                ),
                                sliver: SliverList(
                                  delegate: SliverChildListDelegate([
                                    Center(
                                      child: ConstrainedBox(
                                        constraints: const BoxConstraints(
                                          maxWidth: 1100,
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Expanded(
                                                  child: Column(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: [
                                                      Text(
                                                        activePage == 0
                                                            ? 'Your audience, at a glance'
                                                            : activePage == 1
                                                            ? 'Your connections'
                                                            : 'Settings',
                                                        style: TextStyle(
                                                          color: _primaryText(
                                                            context,
                                                          ),
                                                          fontSize: compact
                                                              ? 24
                                                              : 30,
                                                          fontWeight:
                                                              FontWeight.w800,
                                                          letterSpacing: -.7,
                                                        ),
                                                      ),
                                                      const SizedBox(height: 7),
                                                      Text(
                                                        activePage == 0
                                                            ? (hasData
                                                                  ? 'A clear picture of your Instagram connections.'
                                                                  : 'Understand who follows you back and who you follow.')
                                                            : activePage == 1
                                                            ? 'Search accounts and review how you’re connected.'
                                                            : 'Personalize how SocialScope looks on this device.',
                                                        style: TextStyle(
                                                          color: _secondaryText(
                                                            context,
                                                          ),
                                                          fontSize: 14,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                                if (!compact && activePage == 0)
                                                  FilledButton.icon(
                                                    onPressed: _openImport,
                                                    icon: const Icon(
                                                      Icons.add,
                                                      size: 19,
                                                    ),
                                                    label: const Text(
                                                      'Import data',
                                                    ),
                                                    style: FilledButton.styleFrom(
                                                      backgroundColor: violet,
                                                      padding:
                                                          const EdgeInsets.symmetric(
                                                            horizontal: 18,
                                                            vertical: 15,
                                                          ),
                                                    ),
                                                  ),
                                              ],
                                            ),
                                            if (compact && activePage == 0) ...[
                                              const SizedBox(height: 18),
                                              SizedBox(
                                                width: double.infinity,
                                                child: FilledButton.icon(
                                                  onPressed: _openImport,
                                                  icon: const Icon(Icons.add),
                                                  label: const Text(
                                                    'Import Instagram data',
                                                  ),
                                                  style: FilledButton.styleFrom(
                                                    backgroundColor: violet,
                                                    padding:
                                                        const EdgeInsets.all(
                                                          15,
                                                        ),
                                                  ),
                                                ),
                                              ),
                                            ],
                                            if (activePage == 0) ...[
                                              const SizedBox(height: 26),
                                              LayoutBuilder(
                                                builder: (context, box) {
                                                  final cols =
                                                      box.maxWidth < 570
                                                      ? 2
                                                      : 3;
                                                  final cards = [
                                                    _StatCard(
                                                      label: 'Followers',
                                                      value: _visibleCount(
                                                        followers,
                                                      ),
                                                      icon: Icons
                                                          .people_alt_outlined,
                                                      color: const Color(
                                                        0xFF7657F6,
                                                      ),
                                                      tint: const Color(
                                                        0xFFF0EDFF,
                                                      ),
                                                      onTap: () =>
                                                          _selectList(1),
                                                    ),
                                                    _StatCard(
                                                      label: 'Following',
                                                      value: _visibleCount(
                                                        following,
                                                      ),
                                                      icon: Icons
                                                          .person_add_alt_1_outlined,
                                                      color: const Color(
                                                        0xFF168F78,
                                                      ),
                                                      tint: const Color(
                                                        0xFFE8F7F2,
                                                      ),
                                                      onTap: () =>
                                                          _selectList(2),
                                                    ),
                                                    _StatCard(
                                                      label:
                                                          'Don’t follow back',
                                                      value: _visibleCount(
                                                        notFollowingBack,
                                                      ),
                                                      icon: Icons
                                                          .person_remove_alt_1_outlined,
                                                      color: const Color(
                                                        0xFFE17B54,
                                                      ),
                                                      tint: const Color(
                                                        0xFFFFF1EA,
                                                      ),
                                                      onTap: () =>
                                                          _selectList(3),
                                                    ),
                                                    _StatCard(
                                                      label: 'You don’t follow back',
                                                      value: _visibleCount(
                                                        notFollowedBack,
                                                      ),
                                                      icon: Icons
                                                          .person_add_alt_1_outlined,
                                                      color: const Color(
                                                        0xFF4C83D9,
                                                      ),
                                                      tint: const Color(
                                                        0xFFECF3FF,
                                                      ),
                                                      onTap: () =>
                                                          _selectList(4),
                                                    ),
                                                    _StatCard(
                                                      label: 'Mutuals',
                                                      value: _visibleCount(
                                                        mutuals,
                                                      ),
                                                      icon: Icons
                                                          .sync_alt_rounded,
                                                      color: const Color(
                                                        0xFF4C83D9,
                                                      ),
                                                      tint: const Color(
                                                        0xFFECF3FF,
                                                      ),
                                                      onTap: () =>
                                                          _selectList(5),
                                                    ),
                                                    _StatCard(
                                                      label: 'Close friends',
                                                      value: _visibleCount(
                                                        closeFriends,
                                                      ),
                                                      icon: Icons
                                                          .star_outline_rounded,
                                                      color: const Color(
                                                        0xFFC14D8A,
                                                      ),
                                                      tint: const Color(
                                                        0xFFFFEDF5,
                                                      ),
                                                      onTap: () =>
                                                          _selectList(6),
                                                    ),
                                                    _StatCard(
                                                      label: 'Close friends not following back',
                                                      value: _visibleCount(
                                                        closeFriendsNotFollowingBack,
                                                      ),
                                                      icon: Icons
                                                          .person_remove_alt_1_outlined,
                                                      color: const Color(
                                                        0xFFB56586,
                                                      ),
                                                      tint: const Color(
                                                        0xFFFFF0F5,
                                                      ),
                                                      onTap: () =>
                                                          _selectList(7),
                                                    ),
                                                    _StatCard(
                                                      label: 'Blocked accounts',
                                                      value: _visibleCount(
                                                        blockedAccounts,
                                                      ),
                                                      icon:
                                                          Icons.block_outlined,
                                                      color: const Color(
                                                        0xFF9E4141,
                                                      ),
                                                      tint: const Color(
                                                        0xFFFFEEEE,
                                                      ),
                                                      onTap: () =>
                                                          _selectList(8),
                                                    ),
                                                    _StatCard(
                                                      label: 'Not found',
                                                      value: notFoundAccounts
                                                          .length,
                                                      icon: Icons
                                                          .person_off_outlined,
                                                      color: const Color(
                                                        0xFF9E4141,
                                                      ),
                                                      tint: const Color(
                                                        0xFFFFEEEE,
                                                      ),
                                                      onTap: () =>
                                                          _selectList(9),
                                                    ),
                                                  ];
                                                  return GridView.count(
                                                    shrinkWrap: true,
                                                    physics:
                                                        const NeverScrollableScrollPhysics(),
                                                    crossAxisCount: cols,
                                                    crossAxisSpacing: 14,
                                                    mainAxisSpacing: 14,
                                                    childAspectRatio: compact
                                                        ? 1.55
                                                        : 2.1,
                                                    children: cards,
                                                  );
                                                },
                                              ),
                                            ] else if (activePage == 1) ...[
                                              const SizedBox(height: 28),
                                              _PeoplePanel(
                                                hasData: hasData,
                                                selectedTab: selectedTab,
                                                users: users,
                                                sortMode: sortMode,
                                                onSort: _setSortMode,
                                                onTab: _selectList,
                                                onQuery: _onQueryChanged,
                                                onImport: _openImport,
                                                selectedAccounts:
                                                    selectedReviewAccounts,
                                                openedAccounts: visitedProfiles,
                                                onToggleAll:
                                                    _toggleAllVisibleReviewAccounts,
                                                onToggleAccount:
                                                    _toggleReviewAccount,
                                                onOpenSelected:
                                                    _openSelectedReviewQueue,
                                              ),
                                            ] else ...[
                                              const SizedBox(height: 28),
                                              _SettingsPanel(
                                                themeMode: widget.themeMode,
                                                onThemeModeChanged:
                                                    widget.onThemeModeChanged,
                                                hasData: hasData,
                                                canClear:
                                                    hasData ||
                                                    visitedProfiles
                                                        .isNotEmpty ||
                                                    notFoundAccounts
                                                        .isNotEmpty ||
                                                    lastImportAt != null,
                                                defaultTab: defaultTab,
                                                defaultSortMode:
                                                    defaultSortMode,
                                                followDateDisplay:
                                                    followDateDisplay,
                                                onDefaultTabChanged:
                                                    _setDefaultTab,
                                                onDefaultSortChanged:
                                                    _setDefaultSortMode,
                                                onFollowDateDisplayChanged:
                                                    _setFollowDateDisplay,
                                                onSaveBackup:
                                                    _exportLocalBackup,
                                                onRestoreBackup:
                                                    _restoreLocalBackup,
                                                onClearData: _clearSavedData,
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                    ),
                                  ]),
                                ),
                              ),
                              if (activePage == 1 &&
                                  hasData &&
                                  users.isNotEmpty)
                                SliverPadding(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: compact ? 20 : 42,
                                  ),
                                  sliver: SliverList(
                                    delegate: SliverChildBuilderDelegate((
                                      context,
                                      index,
                                    ) {
                                      final user = users[index];
                                      return Center(
                                        child: ConstrainedBox(
                                          constraints: const BoxConstraints(
                                            maxWidth: 1100,
                                          ),
                                          child: Container(
                                            decoration: BoxDecoration(
                                              color:
                                                  visitedProfiles.contains(
                                                    user.toLowerCase(),
                                                  )
                                                  ? (Theme.of(context)
                                                                .brightness ==
                                                            Brightness.dark
                                                        ? const Color(
                                                            0xFF183329,
                                                          )
                                                        : const Color(
                                                            0xFFEAF7F0,
                                                          ))
                                                  : _surface(context),
                                              border: Border(
                                                left: BorderSide(
                                                  color: _surfaceBorder(
                                                    context,
                                                  ),
                                                ),
                                                right: BorderSide(
                                                  color: _surfaceBorder(
                                                    context,
                                                  ),
                                                ),
                                                bottom: BorderSide(
                                                  color: _surfaceBorder(
                                                    context,
                                                  ),
                                                ),
                                                top: BorderSide.none,
                                              ),
                                              borderRadius:
                                                  BorderRadius.vertical(
                                                    bottom:
                                                        index ==
                                                            users.length - 1
                                                        ? const Radius.circular(
                                                            17,
                                                          )
                                                        : Radius.zero,
                                                  ),
                                            ),
                                            child: _UserRow(
                                              user: user,
                                              followsYou: followers.contains(
                                                user,
                                              ),
                                              youFollow: following.contains(
                                                user,
                                              ),
                                              blocked: blockedAccounts.contains(
                                                user,
                                              ),
                                              daysFollowedYou: _daysSince(
                                                followerTimestamps[user],
                                              ),
                                              daysYouFollow: _daysSince(
                                                followingTimestamps[user],
                                              ),
                                              followerTimestamp:
                                                  followerTimestamps[user],
                                              followingTimestamp:
                                                  followingTimestamps[user],
                                              followDateDisplay:
                                                  followDateDisplay,
                                              selectable:
                                                  selectedTab == 3 &&
                                                  !visitedProfiles.contains(
                                                    user.toLowerCase(),
                                                  ),
                                              isSelected: selectedReviewAccounts
                                                  .contains(user),
                                              onSelectionChanged: (selected) =>
                                                  _toggleReviewAccount(
                                                    user,
                                                    selected,
                                                  ),
                                              marked: visitedProfiles.contains(
                                                user.toLowerCase(),
                                              ),
                                              notFound: notFoundAccounts
                                                  .contains(user.toLowerCase()),
                                              onToggleNotFound: () =>
                                                  _toggleNotFoundAccount(user),
                                              onOpen: () =>
                                                  _openInstagramProfile(user),
                                            ),
                                          ),
                                        ),
                                      );
                                    }, childCount: users.length),
                                  ),
                                ),
                              SliverPadding(
                                padding: EdgeInsets.fromLTRB(
                                  compact ? 20 : 42,
                                  22,
                                  compact ? 20 : 42,
                                  28,
                                ),
                                sliver: SliverToBoxAdapter(
                                  child: Center(
                                    child: ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        maxWidth: 1100,
                                      ),
                                      child: const _PrivacyNote(),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: compact
          ? NavigationBar(
              selectedIndex: activePage,
              onDestinationSelected: _selectPage,
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.grid_view_rounded),
                  label: 'Overview',
                ),
                NavigationDestination(
                  icon: Icon(Icons.people_outline),
                  label: 'Accounts',
                ),
                NavigationDestination(
                  icon: Icon(Icons.settings_outlined),
                  label: 'Settings',
                ),
              ],
            )
          : null,
    );
  }
}

class _SettingsPanel extends StatelessWidget {
  const _SettingsPanel({
    required this.themeMode,
    required this.onThemeModeChanged,
    required this.hasData,
    required this.canClear,
    required this.defaultTab,
    required this.defaultSortMode,
    required this.followDateDisplay,
    required this.onDefaultTabChanged,
    required this.onDefaultSortChanged,
    required this.onFollowDateDisplayChanged,
    required this.onSaveBackup,
    required this.onRestoreBackup,
    required this.onClearData,
  });
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;
  final bool hasData, canClear;
  final int defaultTab, defaultSortMode;
  final String followDateDisplay;
  final ValueChanged<int> onDefaultTabChanged, onDefaultSortChanged;
  final ValueChanged<String> onFollowDateDisplayChanged;
  final VoidCallback onSaveBackup, onRestoreBackup, onClearData;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(22),
    decoration: BoxDecoration(
      color: _surface(context),
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: _surfaceBorder(context)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Appearance',
          style: TextStyle(
            color: _primaryText(context),
            fontSize: 17,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          'System follows your device setting. Light and Dark apply only to SocialScope.',
          style: TextStyle(color: _secondaryText(context), fontSize: 12),
        ),
        const SizedBox(height: 18),
        SizedBox(
          width: double.infinity,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SegmentedButton<ThemeMode>(
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: const [
                ButtonSegment(
                  value: ThemeMode.system,
                  label: Text('System'),
                  icon: Icon(Icons.brightness_auto_outlined),
                ),
                ButtonSegment(
                  value: ThemeMode.light,
                  label: Text('Light'),
                  icon: Icon(Icons.light_mode_outlined),
                ),
                ButtonSegment(
                  value: ThemeMode.dark,
                  label: Text('Dark'),
                  icon: Icon(Icons.dark_mode_outlined),
                ),
              ],
              selected: {themeMode},
              onSelectionChanged: (selection) =>
                  onThemeModeChanged(selection.first),
            ),
          ),
        ),
        const SizedBox(height: 28),
        _settingsHeading(context, 'Follow date display'),
        const SizedBox(height: 5),
        Text(
          'Choose how imported follow dates appear in account lists.',
          style: TextStyle(color: _secondaryText(context), fontSize: 12),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: LayoutBuilder(
            builder: (context, _) => FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'days', label: Text('Days')),
                  ButtonSegment(value: 'date', label: Text('Calendar date')),
                  ButtonSegment(value: 'hidden', label: Text('Hide')),
                ],
                selected: {followDateDisplay},
                onSelectionChanged: (selection) =>
                    onFollowDateDisplayChanged(selection.first),
              ),
            ),
          ),
        ),
        const SizedBox(height: 28),
        _settingsHeading(context, 'Default Accounts view'),
        const SizedBox(height: 12),
        DropdownButtonFormField<int>(
          initialValue: defaultTab,
          decoration: const InputDecoration(
            labelText: 'Open this list by default',
          ),
          items: List.generate(
            _PeoplePanel.labels.length,
            (index) => DropdownMenuItem(
              value: index,
              child: Text(_PeoplePanel.labels[index]),
            ),
          ),
          onChanged: (value) {
            if (value != null) onDefaultTabChanged(value);
          },
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<int>(
          initialValue: defaultSortMode,
          decoration: const InputDecoration(labelText: 'Default sort order'),
          items: List.generate(
            _PeoplePanel.sortLabels.length,
            (index) => DropdownMenuItem(
              value: index,
              child: Text(_PeoplePanel.sortLabels[index]),
            ),
          ),
          onChanged: (value) {
            if (value != null) onDefaultSortChanged(value);
          },
        ),
        const SizedBox(height: 28),
        _settingsHeading(context, 'Privacy'),
        const SizedBox(height: 8),
        Text(
          'Analysis and imported lists stay on this device. When you open a profile, you can manually mark the result after returning from Instagram. SocialScope never asks for your password.',
          style: TextStyle(
            color: _secondaryText(context),
            fontSize: 12,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: () => showDialog<void>(
            context: context,
            builder: (context) => const _PrivacyPolicyDialog(),
          ),
          icon: const Icon(Icons.privacy_tip_outlined, size: 16),
          label: const Text('Read privacy policy'),
        ),
        const SizedBox(height: 20),
        _settingsHeading(context, 'Data management'),
        const SizedBox(height: 5),
        Text(
          'Your imported lists and account marks are stored on this device.',
          style: TextStyle(color: _secondaryText(context), fontSize: 12),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 4,
          runSpacing: 2,
          children: [
            TextButton.icon(
              onPressed: hasData ? onSaveBackup : null,
              icon: const Icon(Icons.download_outlined, size: 17),
              label: const Text('Save local backup'),
            ),
            TextButton.icon(
              onPressed: onRestoreBackup,
              icon: const Icon(Icons.restore_page_outlined, size: 17),
              label: const Text('Restore backup'),
            ),
            TextButton.icon(
              onPressed: canClear ? onClearData : null,
              icon: const Icon(Icons.delete_outline, size: 17),
              label: const Text('Clear saved data'),
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFFB64242),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

Widget _settingsHeading(BuildContext context, String title) => Text(
  title,
  style: TextStyle(
    color: _primaryText(context),
    fontSize: 17,
    fontWeight: FontWeight.w800,
  ),
);

class _PrivacyPolicyDialog extends StatelessWidget {
  const _PrivacyPolicyDialog();

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      'SocialScope Privacy Policy',
      style: TextStyle(
        color: _primaryText(context),
        fontWeight: FontWeight.w800,
      ),
    ),
    content: SizedBox(
      width: 560,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Last updated: November 11, 2026',
              style: TextStyle(color: _secondaryText(context), fontSize: 12),
            ),
            const SizedBox(height: 16),
            _privacySection(
              context,
              'What SocialScope does',
              'SocialScope analyzes Instagram account lists that you choose to import. It compares followers, following, mutuals, close friends, and blocked accounts, and may display follow dates when they are present in the imported JSON export.',
            ),
            _privacySection(
              context,
              'Data processed and stored',
              'The lists you import, follow timestamps, last import time, theme and display preferences, profile links you open, and accounts you mark as not found are stored locally on this device. SocialScope does not send your imported lists to its own server.',
            ),
            _privacySection(
              context,
              'Instagram access',
              'SocialScope does not request your Instagram password or log in to your account. You choose and provide an Instagram data export. You can manually mark an account as not found from the account list or review dialog after checking it in Instagram.',
            ),
            _privacySection(
              context,
              'Backups and sharing',
              'A local backup is created only when you choose Save local backup. The file is written to the location you select and may contain the imported lists and related app data. You control where you store or share it.',
            ),
            _privacySection(
              context,
              'Your choices',
              'You can replace the imported data by importing another export, create or restore a backup, or use Clear saved data in Settings to remove saved app data from this device.',
            ),
            _privacySection(
              context,
              'Children and contact',
              'SocialScope is a personal utility and does not knowingly collect information from children. For privacy questions, contact the app developer through the contact information provided on the app’s store listing.',
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Close'),
      ),
    ],
  );
}

Widget _privacySection(BuildContext context, String heading, String body) =>
    Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            heading,
            style: TextStyle(
              color: _primaryText(context),
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            body,
            style: TextStyle(
              color: _secondaryText(context),
              fontSize: 12,
              height: 1.5,
            ),
          ),
        ],
      ),
    );

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.selectedPage,
    required this.onSelect,
    required this.onImport,
  });
  final int selectedPage;
  final ValueChanged<int> onSelect;
  final VoidCallback onImport;
  @override
  Widget build(BuildContext context) => Container(
    width: 236,
    color: _surface(context),
    padding: const EdgeInsets.fromLTRB(22, 26, 18, 20),
    child: LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(11),
                child: Image.asset(
                  'assets/branding/socialscope-icon.png',
                  width: 48,
                  height: 48,
                  filterQuality: FilterQuality.high,
                ),
              ),
              const SizedBox(height: 44),
              Text(
                'WORKSPACE',
                style: TextStyle(
                  color: _secondaryText(context),
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.4,
                ),
              ),
              const SizedBox(height: 12),
              _NavItem(
                icon: Icons.grid_view_rounded,
                label: 'Overview',
                active: selectedPage == 0,
                onTap: () => onSelect(0),
              ),
              _NavItem(
                icon: Icons.people_outline,
                label: 'Accounts',
                active: selectedPage == 1,
                onTap: () => onSelect(1),
              ),
              _NavItem(
                icon: Icons.settings_outlined,
                label: 'Settings',
                active: selectedPage == 2,
                onTap: () => onSelect(2),
              ),
              const SizedBox(height: 36),
              Container(
                padding: const EdgeInsets.all(15),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.auto_awesome, color: violet, size: 20),
                    const SizedBox(height: 12),
                    Text(
                      'Your data, your device',
                      style: TextStyle(
                        color: _primaryText(context),
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      'No login needed. Analyze your exported data privately.',
                      style: TextStyle(
                        color: _secondaryText(context),
                        height: 1.4,
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(height: 13),
                    TextButton(
                      onPressed: onImport,
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(0, 28),
                        alignment: Alignment.centerLeft,
                      ),
                      child: const Text('Get started →'),
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

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
  });
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(11),
      child: Container(
        margin: const EdgeInsets.only(bottom: 5),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        decoration: BoxDecoration(
          color: active
              ? Theme.of(context).colorScheme.secondaryContainer
              : Colors.transparent,
          borderRadius: BorderRadius.circular(11),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 19,
              color: active ? violet : _secondaryText(context),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: active ? violet : _secondaryText(context),
                  fontSize: 13,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.compact, required this.lastImportAt});
  final bool compact;
  final DateTime? lastImportAt;
  @override
  Widget build(BuildContext context) {
    final timestamp = lastImportAt == null
        ? 'Not yet uploaded'
        : '${MaterialLocalizations.of(context).formatShortDate(lastImportAt!)} · ${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(lastImportAt!), alwaysUse24HourFormat: MediaQuery.of(context).alwaysUse24HourFormat)}';
    return Container(
      height: 70,
      padding: EdgeInsets.symmetric(horizontal: compact ? 20 : 42),
      decoration: BoxDecoration(
        color: _surface(context),
        border: Border(bottom: BorderSide(color: _surfaceBorder(context))),
      ),
      child: Row(
        children: [
          if (compact)
            ClipRRect(
              borderRadius: BorderRadius.circular(7),
              child: Image.asset(
                'assets/branding/socialscope-icon.png',
                width: 30,
                height: 30,
                filterQuality: FilterQuality.high,
              ),
            ),
          const Spacer(),
          Container(
            constraints: const BoxConstraints(maxWidth: 250),
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.schedule_rounded,
                  size: 16,
                  color: _secondaryText(context),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'LAST UPLOAD',
                        style: TextStyle(
                          fontSize: 9,
                          letterSpacing: .8,
                          color: _secondaryText(context),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        timestamp,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: _primaryText(context),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    required this.tint,
    required this.onTap,
  });
  final String label;
  final int value;
  final IconData icon;
  final Color color;
  final Color tint;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(17),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: _surface(context),
          borderRadius: BorderRadius.circular(17),
          border: Border.all(color: _surfaceBorder(context)),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) => FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: constraints.maxWidth,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: tint,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(icon, size: 17, color: color),
                      ),
                      const Spacer(),
                      Icon(Icons.arrow_forward, size: 15, color: color),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Text(
                    '$value',
                    style: TextStyle(
                      color: _primaryText(context),
                      fontSize: 25,
                      fontWeight: FontWeight.w800,
                      height: 1,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _secondaryText(context),
                      fontSize: 11,
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
  );
}

class _PeoplePanel extends StatelessWidget {
  const _PeoplePanel({
    required this.hasData,
    required this.selectedTab,
    required this.users,
    required this.sortMode,
    required this.onSort,
    required this.onTab,
    required this.onQuery,
    required this.onImport,
    required this.selectedAccounts,
    required this.openedAccounts,
    required this.onToggleAll,
    required this.onToggleAccount,
    required this.onOpenSelected,
  });
  final bool hasData;
  final int selectedTab;
  final List<String> users;
  final int sortMode;
  final ValueChanged<int> onSort;
  final ValueChanged<int> onTab;
  final ValueChanged<String> onQuery;
  final VoidCallback onImport;
  final Set<String> selectedAccounts;
  final Set<String> openedAccounts;
  final VoidCallback onToggleAll;
  final void Function(String username, bool selected) onToggleAccount;
  final VoidCallback onOpenSelected;
  static const labels = [
    'All accounts',
    'Followers',
    'Following',
    'Don’t follow back',
    'You don’t follow back',
    'Mutuals',
    'Close friends',
    'Close friends not following back',
    'Blocked accounts',
    'Not found',
  ];
  static const sortLabels = [
    'Name A–Z',
    'Name Z–A',
    'Follows you: oldest first',
    'Follows you: newest first',
    'You follow: oldest first',
    'You follow: newest first',
  ];
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: _surface(context),
      borderRadius: BorderRadius.vertical(
        top: const Radius.circular(19),
        bottom: hasData && users.isNotEmpty
            ? Radius.zero
            : const Radius.circular(19),
      ),
      border: Border.all(color: _surfaceBorder(context)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (selectedTab == 3 && hasData)
          Builder(
            builder: (context) {
              final unopenedUsers = users
                  .where((user) => !openedAccounts.contains(user.toLowerCase()))
                  .toList();
              final allUnopenedSelected =
                  unopenedUsers.isNotEmpty &&
                  unopenedUsers.every(selectedAccounts.contains);
              return Padding(
                padding: const EdgeInsets.fromLTRB(22, 14, 22, 0),
                child: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 4,
                  runSpacing: 0,
                  children: [
                    TextButton(
                      onPressed: unopenedUsers.isEmpty ? null : onToggleAll,
                      child: Text(
                        allUnopenedSelected ? 'Deselect all' : 'Select all',
                      ),
                    ),
                    Text(
                      '${selectedAccounts.length} selected',
                      style: TextStyle(
                        color: _secondaryText(context),
                        fontSize: 12,
                      ),
                    ),
                    TextButton.icon(
                      onPressed: selectedAccounts.isEmpty
                          ? null
                          : onOpenSelected,
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: const Text('Review selected'),
                    ),
                  ],
                ),
              );
            },
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 14),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final search = hasData
                  ? SizedBox(
                      width: constraints.maxWidth < 520 ? double.infinity : 220,
                      height: 38,
                      child: TextField(
                        key: ValueKey(selectedTab),
                        onChanged: onQuery,
                        decoration: InputDecoration(
                          hintText: 'Search username',
                          prefixIcon: const Icon(Icons.search, size: 17),
                          contentPadding: EdgeInsets.zero,
                          filled: true,
                          fillColor: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide.none,
                          ),
                          hintStyle: TextStyle(
                            fontSize: 12,
                            color: _secondaryText(context),
                          ),
                        ),
                      ),
                    )
                  : const SizedBox.shrink();
              final heading = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Your connections',
                    style: TextStyle(
                      color: _primaryText(context),
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Browse and search your audience',
                    style: TextStyle(
                      color: _secondaryText(context),
                      fontSize: 12,
                    ),
                  ),
                ],
              );
              if (constraints.maxWidth < 520) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    heading,
                    if (hasData) ...[const SizedBox(height: 12), search],
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: heading),
                  if (hasData) search,
                ],
              );
            },
          ),
        ),
        if (hasData)
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 0, 22, 10),
            child: Row(
              children: [
                Icon(
                  Icons.sort_rounded,
                  color: _secondaryText(context),
                  size: 18,
                ),
                const SizedBox(width: 8),
                Text(
                  'Sort by',
                  style: TextStyle(
                    color: _secondaryText(context),
                    fontSize: 12,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: DropdownButton<int>(
                    value: sortMode,
                    isExpanded: true,
                    underline: const SizedBox.shrink(),
                    style: TextStyle(
                      color: _primaryText(context),
                      fontSize: 12,
                    ),
                    items: List.generate(
                      sortLabels.length,
                      (index) => DropdownMenuItem(
                        value: index,
                        child: Text(
                          sortLabels[index],
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    onChanged: (value) {
                      if (value != null) onSort(value);
                    },
                  ),
                ),
              ],
            ),
          ),
        if (hasData)
          SizedBox(
            width: double.infinity,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics(),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 22),
              child: Row(
                children: List.generate(
                  labels.length,
                  (i) => Padding(
                    padding: const EdgeInsets.only(right: 7),
                    child: ChoiceChip(
                      label: Text(labels[i]),
                      selected: selectedTab == i,
                      onSelected: (_) => onTab(i),
                      selectedColor: Theme.of(context)
                          .colorScheme
                          .secondaryContainer,
                      backgroundColor: _surface(context),
                      side: BorderSide(
                        color: selectedTab == i
                            ? violet
                            : _surfaceBorder(context),
                      ),
                      labelStyle: TextStyle(
                        color: selectedTab == i
                            ? violet
                            : _secondaryText(context),
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ),
              ),
            ),
          ),
        if (hasData && selectedTab == 3)
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 12, 22, 0),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF8F3),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Row(
                children: [
                  Icon(Icons.info_outline, size: 16, color: Color(0xFFB96A42)),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Open a profile, then tap Following in Instagram if you want to unfollow.',
                      style: TextStyle(color: Color(0xFF8A593F), fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (hasData && selectedTab == 9)
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 12, 22, 0),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 16,
                    color: _secondaryText(context),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Open profiles in Instagram, then manually mark unavailable accounts as not found from the account row or review dialog. Marked accounts are hidden from other lists and counts.',
                      style: TextStyle(
                        color: _secondaryText(context),
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        Divider(height: 20, color: _surfaceBorder(context)),
        if (!hasData)
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 18, 22, 28),
            child: _EmptyState(onImport: onImport),
          )
        else if (users.isEmpty)
          Padding(
            padding: const EdgeInsets.all(32),
            child: Center(
              child: Text(
                selectedTab == 9
                    ? 'No accounts marked as not found yet. Open a profile from an account list and confirm its status when you return to the app.'
                    : selectedTab == 6 || selectedTab == 7
                    ? 'No Close Friends entries found. Include Close Friends in your Instagram export if that option is available.'
                    : selectedTab == 8
                    ? 'No blocked accounts found in this export. Include blocked profiles in your Instagram export if available.'
                    : 'No accounts match this view.',
                textAlign: TextAlign.center,
                style: TextStyle(color: _secondaryText(context), fontSize: 13),
              ),
            ),
          ),
      ],
    ),
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onImport});
  final VoidCallback onImport;
  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      children: [
        Container(
          width: 58,
          height: 58,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.secondaryContainer,
            borderRadius: BorderRadius.circular(18),
          ),
          child: const Icon(Icons.people_alt_outlined, color: violet, size: 27),
        ),
        const SizedBox(height: 14),
        Text(
          'Bring your Instagram data in',
          style: TextStyle(
            color: _primaryText(context),
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Import your followers and following lists to see your connections.',
          textAlign: TextAlign.center,
          style: TextStyle(color: _secondaryText(context), fontSize: 12),
        ),
        const SizedBox(height: 15),
        OutlinedButton.icon(
          onPressed: onImport,
          icon: const Icon(Icons.upload_file_outlined, size: 17),
          label: const Text('Import lists'),
          style: OutlinedButton.styleFrom(
            foregroundColor: violet,
            side: BorderSide(color: _surfaceBorder(context)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        ),
      ],
    ),
  );
}

int? _daysSince(int? timestamp) {
  if (timestamp == null || timestamp <= 0) return null;
  final milliseconds = timestamp > 1000000000000 ? timestamp : timestamp * 1000;
  final days = DateTime.now()
      .difference(DateTime.fromMillisecondsSinceEpoch(milliseconds))
      .inDays;
  return days < 0 ? 0 : days;
}

String _followDurationLabel(
  String label,
  int timestamp,
  int days,
  String mode,
) {
  if (mode == 'date') {
    final milliseconds = timestamp > 1000000000000
        ? timestamp
        : timestamp * 1000;
    final date = DateTime.fromMillisecondsSinceEpoch(milliseconds);
    final dateText =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    return '$label since $dateText';
  }
  return '$label: $days ${days == 1 ? 'day' : 'days'}';
}

class _UserRow extends StatelessWidget {
  const _UserRow({
    required this.user,
    required this.followsYou,
    required this.youFollow,
    required this.blocked,
    required this.daysFollowedYou,
    required this.daysYouFollow,
    required this.followerTimestamp,
    required this.followingTimestamp,
    required this.followDateDisplay,
    required this.selectable,
    required this.isSelected,
    required this.onSelectionChanged,
    required this.marked,
    required this.notFound,
    required this.onToggleNotFound,
    required this.onOpen,
  });
  final String user;
  final bool followsYou, youFollow, blocked, marked, notFound;
  final int? daysFollowedYou, daysYouFollow;
  final int? followerTimestamp, followingTimestamp;
  final String followDateDisplay;
  final bool selectable, isSelected;
  final ValueChanged<bool> onSelectionChanged;
  final VoidCallback onOpen;
  final VoidCallback onToggleNotFound;
  @override
  Widget build(BuildContext context) {
    final initials = user.replaceAll('@', '').characters.first.toUpperCase();
    final ageDetails = <String>[];
    if (followDateDisplay != 'hidden' && daysFollowedYou != null && followsYou)
      ageDetails.add(
        _followDurationLabel(
          'Follows you',
          followerTimestamp!,
          daysFollowedYou!,
          followDateDisplay,
        ),
      );
    if (followDateDisplay != 'hidden' && daysYouFollow != null && youFollow)
      ageDetails.add(
        _followDurationLabel(
          'You follow',
          followingTimestamp!,
          daysYouFollow!,
          followDateDisplay,
        ),
      );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 400;
          final tagColor = blocked
              ? const Color(0xFF9E4141)
              : followsYou && youFollow
              ? const Color(0xFF168F78)
              : followsYou
              ? const Color(0xFF4C83D9)
              : const Color(0xFFE17B54);
          final tagText = blocked
              ? 'Blocked'
              : followsYou && youFollow
              ? 'Mutual'
              : followsYou
              ? 'You don’t follow back'
              : youFollow
              ? 'They don’t follow back'
              : 'No longer following';
          return Row(
            children: [
              CircleAvatar(
                radius: 19,
                backgroundColor: const Color(0xFFF1EEFF),
                child: Text(
                  initials,
                  style: const TextStyle(
                    color: violet,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '@${user.replaceAll('@', '')}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: _primaryText(context),
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (ageDetails.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        ageDetails.join(' · '),
                        style: TextStyle(
                          color: _secondaryText(context),
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (compact)
                Tooltip(
                  message: tagText,
                  child: Icon(Icons.circle, color: tagColor, size: 10),
                )
              else
                _Tag(text: tagText, color: tagColor),
              if (selectable)
                Checkbox(
                  value: isSelected,
                  onChanged: (value) => onSelectionChanged(value ?? false),
                  visualDensity: VisualDensity.compact,
                ),
              const SizedBox(width: 7),
              if (marked)
                const Icon(
                  Icons.check_circle,
                  color: Color(0xFF168F78),
                  size: 17,
                ),
              IconButton(
                onPressed: onToggleNotFound,
                tooltip: notFound
                    ? 'Remove from Not found list'
                    : 'Mark as not found after checking Instagram',
                icon: Icon(
                  notFound ? Icons.person_off : Icons.person_off_outlined,
                  color: notFound
                      ? const Color(0xFF9E4141)
                      : _secondaryText(context),
                  size: 17,
                ),
                visualDensity: VisualDensity.compact,
              ),
              IconButton(
                onPressed: onOpen,
                tooltip: marked
                    ? 'Reopen Instagram profile'
                    : 'Open Instagram profile',
                icon: const Icon(Icons.open_in_new, color: violet, size: 17),
                visualDensity: VisualDensity.compact,
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ReviewQueueDialog extends StatefulWidget {
  const _ReviewQueueDialog({
    required this.accounts,
    required this.notFoundAccounts,
    required this.onOpen,
    required this.onSetNotFound,
  });
  final List<String> accounts;
  final Set<String> notFoundAccounts;
  final ValueChanged<String> onOpen;
  final Future<void> Function(String username, bool marked) onSetNotFound;
  @override
  State<_ReviewQueueDialog> createState() => _ReviewQueueDialogState();
}

class _ReviewQueueDialogState extends State<_ReviewQueueDialog> {
  int index = 0;
  bool openedCurrent = false;
  bool updatingNotFound = false;

  Future<void> _openCurrent() async {
    widget.onOpen(widget.accounts[index]);
    if (mounted) setState(() => openedCurrent = true);
  }

  void _next() {
    if (index + 1 >= widget.accounts.length) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      index++;
      openedCurrent = false;
    });
  }

  Future<void> _toggleNotFound(String username) async {
    final normalized = username.toLowerCase();
    final marked = !widget.notFoundAccounts.contains(normalized);
    setState(() => updatingNotFound = true);
    await widget.onSetNotFound(username, marked);
    if (mounted) setState(() => updatingNotFound = false);
  }

  @override
  Widget build(BuildContext context) {
    final username = widget.accounts[index];
    final isNotFound = widget.notFoundAccounts.contains(username.toLowerCase());
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final progress = (index + 1) / widget.accounts.length;
    final initials = username
        .replaceAll('@', '')
        .characters
        .first
        .toUpperCase();
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 500,
          maxHeight: MediaQuery.sizeOf(context).height * .88,
        ),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        gradient: LinearGradient(
                          colors: [colors.primary, colors.tertiary],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                      ),
                      child: const Icon(
                        Icons.groups_2_outlined,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Review accounts',
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            'Check profiles one at a time',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: _secondaryText(context),
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close review',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Account ${index + 1} of ${widget.accounts.length}',
                      style: theme.textTheme.labelLarge,
                    ),
                    Text(
                      '${(progress * 100).round()}%',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: _secondaryText(context),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 6,
                    backgroundColor: colors.surfaceContainerHighest,
                  ),
                ),
                const SizedBox(height: 22),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 24,
                  ),
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: _surfaceBorder(context)),
                  ),
                  child: Column(
                    children: [
                      CircleAvatar(
                        radius: 34,
                        backgroundColor: colors.primaryContainer,
                        child: Text(
                          initials,
                          style: theme.textTheme.headlineSmall?.copyWith(
                            color: colors.onPrimaryContainer,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        '@$username',
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        openedCurrent
                            ? 'Profile opened. Review it in Instagram, then continue here.'
                            : 'Review this profile in Instagram. If Instagram says the user could not be found, mark it here.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: _secondaryText(context),
                        ),
                      ),
                      const SizedBox(height: 18),
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          FilledButton.icon(
                            onPressed: _openCurrent,
                            icon: const Icon(Icons.open_in_new),
                            label: const Text('Open profile'),
                          ),
                          OutlinedButton.icon(
                            onPressed: updatingNotFound
                                ? null
                                : () => _toggleNotFound(username),
                            icon: Icon(
                              isNotFound
                                  ? Icons.person_off
                                  : Icons.person_off_outlined,
                            ),
                            label: Text(
                              isNotFound
                                  ? 'Marked not found'
                                  : 'Mark not found',
                            ),
                          ),
                          FilledButton.tonalIcon(
                            onPressed: _next,
                            icon: const Icon(Icons.check),
                            label: const Text('Done'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 230),
                      child: Text(
                        'Opened profiles move to the bottom of your list.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: _secondaryText(context),
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Finish'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.color});
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .09),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      text,
      style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w600),
    ),
  );
}

class _PrivacyNote extends StatelessWidget {
  const _PrivacyNote();
  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(Icons.lock_outline, size: 15, color: _secondaryText(context)),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          'Your lists stay on this device. Profile results are confirmed manually after you return from Instagram; SocialScope never asks for your password or logs in.',
          style: TextStyle(
            color: _secondaryText(context),
            fontSize: 11,
            height: 1.4,
          ),
        ),
      ),
    ],
  );
}

class _ImportResult {
  const _ImportResult(this.lists);
  final Map<String, dynamic> lists;
}

class ImportDialog extends StatefulWidget {
  const ImportDialog({super.key});
  @override
  State<ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<ImportDialog> {
  final followersController = TextEditingController();
  final followingController = TextEditingController();
  int importMode = 2;
  String? followersFileName;
  String? followingFileName;
  String? followersFileContent;
  String? followingFileContent;
  String? zipFileName;
  String? error;
  bool isProcessing = false;
  @override
  void dispose() {
    followersController.dispose();
    followingController.dispose();
    super.dispose();
  }

  Future<void> _openInstagramExportPage() async {
    final exportPage = Uri.https(
      'accountscenter.instagram.com',
      '/info_and_permissions/dyi/',
    );
    try {
      final opened = await launchUrl(
        exportPage,
        mode: LaunchMode.externalApplication,
      );
      if (!opened && mounted)
        setState(
          () => error =
              'Could not open Instagram. Use the export path shown above.',
        );
    } catch (_) {
      if (mounted)
        setState(
          () => error =
              'Could not open Instagram. Use the export path shown above.',
        );
    }
  }

  Future<void> _pickFile({required bool isFollowers}) async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['json', 'html', 'htm', 'txt'],
    );
    if (file == null) return;
    try {
      final content = utf8.decode(
        await file.readAsBytes(),
        allowMalformed: true,
      );
      setState(() {
        if (isFollowers) {
          followersFileName = file.name;
          followersFileContent = content;
        } else {
          followingFileName = file.name;
          followingFileContent = content;
        }
        error = null;
      });
    } catch (_) {
      setState(
        () => error =
            'Could not read that file. Choose a JSON, HTML, or text file.',
      );
    }
  }

  Future<void> _pickZip() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['zip'],
    );
    if (file == null) return;
    late final List<int> bytes;
    try {
      bytes = await file.readAsBytes();
    } catch (_) {
      setState(
        () => error = 'Could not read that ZIP file. Please choose the Instagram export archive.',
      );
      return;
    }
    setState(() {
      zipFileName = file.name;
      error = null;
      isProcessing = true;
    });
    try {
      final lists = await compute(_parseExportZip, bytes);
      if (lists['followers']!.isEmpty || lists['following']!.isEmpty) {
        if (mounted)
          setState(
            () => error = 'I couldn’t find both followers and following lists in that ZIP. Make sure it is an Instagram export.',
          );
        return;
      }
      if (mounted) Navigator.of(context).pop(_ImportResult(lists));
    } catch (_) {
      if (mounted)
        setState(
          () => error = 'That ZIP could not be read. Please choose a valid Instagram export ZIP.',
        );
    } finally {
      if (mounted) setState(() => isProcessing = false);
    }
  }

  Future<void> _submit() async {
    setState(() {
      isProcessing = true;
      error = null;
    });
    try {
      final lists = await compute(_parsePastedPair, [
        importMode == 1
            ? (followersFileContent ?? '')
            : followersController.text,
        importMode == 1
            ? (followingFileContent ?? '')
            : followingController.text,
      ]);
      if (lists['followers']!.isEmpty || lists['following']!.isEmpty) {
        if (mounted)
          setState(
            () => error = 'Add both lists. Paste the data or choose a file for each list.',
          );
        return;
      }
      if (mounted) Navigator.of(context).pop(_ImportResult(lists));
    } catch (_) {
      if (mounted)
        setState(
          () => error = 'Could not read those lists. Please check the files and try again.',
        );
    } finally {
      if (mounted) setState(() => isProcessing = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
    title: Text(
      'Import Instagram data',
      style: TextStyle(
        fontWeight: FontWeight.w800,
        color: _primaryText(context),
      ),
    ),
    content: SizedBox(
      width: (MediaQuery.sizeOf(context).width - 88).clamp(0.0, 540.0),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Use your Instagram export. Upload the ZIP once and SocialScope will find the lists for you.',
              style: TextStyle(
                color: _secondaryText(context),
                height: 1.45,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 15),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(13),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'How to export',
                    style: TextStyle(
                      color: _primaryText(context),
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  SizedBox(height: 7),
                  Text(
                    'Instagram → Profile → ☰ → Accounts Center → Your information and permissions → Export your information.',
                    style: TextStyle(
                      color: _primaryText(context),
                      fontSize: 11,
                      height: 1.45,
                    ),
                  ),
                  SizedBox(height: 7),
                  Text(
                    'Choose your Instagram account → Some of your information → Followers and following, Close Friends, and blocked profiles (if available). Set the date range to All time, choose JSON for follow dates (HTML works for list comparison), then create and download the export.',
                    style: TextStyle(
                      color: _secondaryText(context),
                      fontSize: 11,
                      height: 1.45,
                    ),
                  ),
                  SizedBox(height: 6),
                  Text(
                    'All time gives the fullest available data for this comparison.',
                    style: TextStyle(
                      color: violet,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: _openInstagramExportPage,
                      icon: Icon(Icons.open_in_new, size: 16),
                      label: Text('Open Instagram export page'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 15),
            SizedBox(
              width: double.infinity,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(
                  parent: AlwaysScrollableScrollPhysics(),
                ),
                child: SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(
                      value: 0,
                      label: Text('Paste'),
                      icon: Icon(Icons.content_paste),
                    ),
                    ButtonSegment(
                      value: 1,
                      label: Text('Files'),
                      icon: Icon(Icons.upload_file_outlined),
                    ),
                    ButtonSegment(
                      value: 2,
                      label: Text('ZIP export'),
                      icon: Icon(Icons.folder_zip_outlined),
                    ),
                  ],
                  selected: {importMode},
                  onSelectionChanged: isProcessing
                      ? null
                      : (selection) => setState(() {
                          importMode = selection.first;
                          error = null;
                        }),
                ),
              ),
            ),
            const SizedBox(height: 15),
            if (importMode == 0) ...[
              _PasteBox(
                label: 'FOLLOWERS',
                hint: 'Paste followers_1.json, HTML, or usernames',
                controller: followersController,
              ),
              const SizedBox(height: 12),
              _PasteBox(
                label: 'FOLLOWING',
                hint: 'Paste following.json, HTML, or usernames',
                controller: followingController,
              ),
            ] else if (importMode == 1) ...[
              _FilePickRow(
                label: 'FOLLOWERS',
                fileName: followersFileName,
                onPressed: () => _pickFile(isFollowers: true),
              ),
              const SizedBox(height: 12),
              _FilePickRow(
                label: 'FOLLOWING',
                fileName: followingFileName,
                onPressed: () => _pickFile(isFollowers: false),
              ),
            ] else ...[
              Text(
                'Upload the ZIP you downloaded. The app finds and combines the follower and following files inside it.',
                style: TextStyle(
                  color: _secondaryText(context),
                  height: 1.45,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 11),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: isProcessing ? null : _pickZip,
                  icon: const Icon(Icons.folder_zip_outlined, size: 18),
                  label: Text(
                    zipFileName ?? 'Choose Instagram export ZIP',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  style: OutlinedButton.styleFrom(
                    alignment: Alignment.centerLeft,
                    foregroundColor: violet,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 15,
                    ),
                    side: const BorderSide(color: Color(0xFFE1DDF0)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            if (isProcessing) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(color: violet),
              const SizedBox(height: 6),
              Text(
                'Processing your export…',
                style: TextStyle(color: _secondaryText(context), fontSize: 11),
              ),
            ],
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  error!,
                  style: const TextStyle(color: Colors.red, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: isProcessing ? null : () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      if (importMode != 2)
        FilledButton(
          onPressed: isProcessing ? null : _submit,
          style: FilledButton.styleFrom(backgroundColor: violet),
          child: Text(isProcessing ? 'Processing…' : 'Analyze lists'),
        ),
    ],
  );
}

class _FilePickRow extends StatelessWidget {
  const _FilePickRow({
    required this.label,
    required this.fileName,
    required this.onPressed,
  });
  final String label;
  final String? fileName;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: TextStyle(
          color: _primaryText(context),
          fontSize: 10,
          letterSpacing: 1,
          fontWeight: FontWeight.w800,
        ),
      ),
      const SizedBox(height: 6),
      SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: onPressed,
          icon: Icon(
            fileName == null
                ? Icons.upload_file_outlined
                : Icons.check_circle_outline,
            size: 18,
          ),
          label: Text(
            fileName ?? 'Choose JSON, HTML, or text file',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          style: OutlinedButton.styleFrom(
            alignment: Alignment.centerLeft,
            foregroundColor: fileName == null
                ? violet
                : const Color(0xFF168F78),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            side: const BorderSide(color: Color(0xFFE1DDF0)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      ),
    ],
  );
}

class _PasteBox extends StatelessWidget {
  const _PasteBox({
    required this.label,
    required this.hint,
    required this.controller,
  });
  final String label, hint;
  final TextEditingController controller;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: TextStyle(
          color: _primaryText(context),
          fontSize: 10,
          letterSpacing: 1,
          fontWeight: FontWeight.w800,
        ),
      ),
      const SizedBox(height: 6),
      TextField(
        controller: controller,
        maxLines: 4,
        minLines: 3,
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(fontSize: 11, color: _secondaryText(context)),
          filled: true,
          fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
          contentPadding: const EdgeInsets.all(12),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: _surfaceBorder(context)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: _surfaceBorder(context)),
          ),
        ),
      ),
    ],
  );
}
