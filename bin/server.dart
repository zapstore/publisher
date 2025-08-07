import 'dart:convert';
import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';
import 'package:shelf_cors_headers/shelf_cors_headers.dart';
import 'package:shelf_static/shelf_static.dart';

import 'package:crypto/crypto.dart';

import 'package:http/http.dart' as http;
import 'package:bech32/bech32.dart';

// Global state for upload sessions
final Map<String, UploadSession> sessions = {};

// Convert hex pubkey to npub format
String hexToNpub(String hexPubkey) {
  if (hexPubkey.length != 64) {
    throw ArgumentError('Invalid pubkey length: expected 64 hex characters');
  }

  // Convert hex to bytes
  final bytes = <int>[];
  for (int i = 0; i < hexPubkey.length; i += 2) {
    bytes.add(int.parse(hexPubkey.substring(i, i + 2), radix: 16));
  }

  // Convert to 5-bit groups for bech32
  final fiveBitData = <int>[];
  var acc = 0;
  var bits = 0;

  for (final byte in bytes) {
    acc = (acc << 8) | byte;
    bits += 8;

    while (bits >= 5) {
      bits -= 5;
      fiveBitData.add((acc >> bits) & 31);
    }
  }

  if (bits > 0) {
    fiveBitData.add((acc << (5 - bits)) & 31);
  }

  // Encode with bech32
  final bech32codec = Bech32Codec();
  return bech32codec.encode(Bech32('npub', fiveBitData));
}

class UploadSession {
  final String sessionId;
  final String apkPath;
  final String npub;
  final String? repository;
  final List<Map<String, dynamic>> events;

  UploadSession({
    required this.sessionId,
    required this.apkPath,
    required this.npub,
    this.repository,
    required this.events,
  });
}

void main() async {
  // Ensure temp directory exists
  final tempDir = Directory('/tmp');
  if (!await tempDir.exists()) {
    await tempDir.create(recursive: true);
  }

  final handler = Pipeline()
      .addMiddleware(corsHeaders())
      .addMiddleware(logRequests())
      .addHandler(_router);

  final server = await serve(handler, 'localhost', 3335);
  print('🚀 Server running on http://localhost:${server.port}');
  print('📱 APK Publisher ready for retro publishing!');
}

Handler _router = (Request request) {
  final path = request.url.path;

  if (path.startsWith('api/process') && request.method == 'POST') {
    return _handleProcess(request);
  } else if (path.startsWith('api/publish') && request.method == 'POST') {
    return _handlePublish(request);
  } else {
    // Serve static files
    return createStaticHandler('web', defaultDocument: 'index.html')(request);
  }
};

Future<Response> _handleProcess(Request request) async {
  String? apkPath;
  String? yamlPath;

  try {
    print('📤 Processing APK from URL...');

    final body = await request.readAsString();
    final data = jsonDecode(body) as Map<String, dynamic>;

    final apkUrl = data['apkUrl'] as String?;
    final pubkey = data['npub'] as String?;
    final repository = data['repository'] as String?;
    final iconUrl = data['iconUrl'] as String?;
    final description = data['description'] as String?;
    final license = data['license'] as String?;

    if (apkUrl == null || pubkey == null) {
      return Response.badRequest(
        body: jsonEncode({'error': 'Missing apkUrl or npub'}),
        headers: {'content-type': 'application/json'},
      );
    }

    // Validate required fields
    if (repository == null || repository.isEmpty) {
      return Response.badRequest(
        body: jsonEncode({'error': 'Repository URL is required'}),
        headers: {'content-type': 'application/json'},
      );
    }

    if (iconUrl == null || iconUrl.isEmpty) {
      return Response.badRequest(
        body: jsonEncode({'error': 'Icon URL is required'}),
        headers: {'content-type': 'application/json'},
      );
    }

    // Validate URL
    final uri = Uri.tryParse(apkUrl);
    if (uri == null || (!uri.scheme.startsWith('http'))) {
      return Response.badRequest(
        body: jsonEncode({'error': 'Invalid APK URL'}),
        headers: {'content-type': 'application/json'},
      );
    }

    print('📥 Downloading APK from: $apkUrl');

    // Download APK from URL
    final httpClient = http.Client();
    List<int> apkBytes;
    try {
      final downloadResponse = await httpClient.get(uri);

      if (downloadResponse.statusCode != 200) {
        throw Exception(
            'Failed to download APK: HTTP ${downloadResponse.statusCode}');
      }

      apkBytes = downloadResponse.bodyBytes;
    } finally {
      httpClient.close();
    }

    // Calculate SHA-256 hash
    final hash = sha256.convert(apkBytes);
    final hashString = hash.toString();
    apkPath = '/tmp/$hashString.apk';

    print('💾 Saving APK: $apkPath');

    // Save APK file
    final apkFile = File(apkPath);
    await apkFile.writeAsBytes(apkBytes);

    // Create YAML configuration
    yamlPath = '/tmp/$hashString.yaml';
    final yamlContent =
        _createYamlConfig(repository, apkPath, iconUrl, description, license);
    await File(yamlPath).writeAsString(yamlContent);

    print('⚙️ Running zapstore publish...');

    // Convert hex pubkey to npub format for SIGN_WITH
    final npub = hexToNpub(pubkey);
    print('🔑 Using npub: $npub');

    // Run zapstore command with SIGN_WITH environment variable
    final result = await Process.run('zapstore',
        ['publish', '-c', yamlPath, '--indexer-mode', '--overwrite-release'],
        environment: {'SIGN_WITH': npub});

    if (result.exitCode != 0) {
      print('❌ Zapstore command failed:');
      print('Exit code: ${result.exitCode}');
      print('STDOUT: ${result.stdout}');
      print('STDERR: ${result.stderr}');
      return Response.internalServerError(
        body:
            jsonEncode({'error': 'zapstore command failed: ${result.stderr}'}),
        headers: {'content-type': 'application/json'},
      );
    }

    // Check zapstore output for failures first
    final output = result.stdout.toString().trim();
    print('✅ Zapstore command completed!');
    print('📋 Zapstore output: $output');
    print('📋 Zapstore stderr: ${result.stderr}');

    // Check if output contains failure messages
    if (output.contains('Failure:')) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'zapstore publish failed: $output'}),
        headers: {'content-type': 'application/json'},
      );
    }

    // Parse zapstore output (JSONL format - multiple JSON objects, one per line)
    List<Map<String, dynamic>> events = [];
    try {
      final lines =
          output.split('\n').where((line) => line.trim().isNotEmpty).toList();

      for (final line in lines) {
        try {
          final decoded = jsonDecode(line.trim());
          if (decoded is Map<String, dynamic>) {
            events.add(decoded);
          }
        } catch (e) {
          // Skip non-JSON lines (like status messages)
          print('⚠️ Skipping non-JSON line: $line');
        }
      }

      if (events.isEmpty) {
        throw Exception('No valid JSON events found in zapstore output');
      }
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to parse zapstore output: $e'}),
        headers: {'content-type': 'application/json'},
      );
    }

    // Create session
    final sessionId = _generateSessionId();
    sessions[sessionId] = UploadSession(
      sessionId: sessionId,
      apkPath: apkPath,
      npub: npub,
      repository: repository,
      events: events,
    );

    print('✅ APK processed successfully, session: $sessionId');

    return Response.ok(
      jsonEncode({
        'sessionId': sessionId,
        'events': events,
        'message': 'APK processed successfully. Please sign the events.',
      }),
      headers: {'content-type': 'application/json'},
    );
  } catch (e, stackTrace) {
    print('❌ Processing error: $e');
    print('Stack trace: $stackTrace');
    return Response.internalServerError(
      body: jsonEncode({'error': 'Processing failed: $e'}),
      headers: {'content-type': 'application/json'},
    );
  } finally {
    // Always clean up temporary files
    print('🧹 Cleaning up temporary files...');
    if (yamlPath != null) {
      try {
        await File(yamlPath).delete();
        print('✅ Cleaned up YAML file: $yamlPath');
      } catch (e) {
        print('⚠️ Failed to delete YAML file: $e');
      }
    }
    if (apkPath != null) {
      try {
        await File(apkPath).delete();
        print('✅ Cleaned up APK file: $apkPath');
      } catch (e) {
        print('⚠️ Failed to delete APK file: $e');
      }
    }
  }
}

Future<Response> _handlePublish(Request request) async {
  try {
    print('📡 Publishing signed events...');

    final body = await request.readAsString();
    final data = jsonDecode(body) as Map<String, dynamic>;

    final sessionId = data['sessionId'] as String?;
    final signedEvents = data['signedEvents'] as List?;

    if (sessionId == null || signedEvents == null) {
      return Response.badRequest(
        body: jsonEncode({'error': 'Missing sessionId or signedEvents'}),
        headers: {'content-type': 'application/json'},
      );
    }

    final session = sessions[sessionId];
    if (session == null) {
      return Response.badRequest(
        body: jsonEncode({'error': 'Invalid session ID'}),
        headers: {'content-type': 'application/json'},
      );
    }

    // zapstore command already handles file upload
    print('✅ File upload handled by zapstore command');

    print('⚡ Publishing events to relay...');

    // Publish events to relay using nak
    final publishResult =
        await _publishToRelay(signedEvents.cast<Map<String, dynamic>>());
    if (!publishResult) {
      return Response.internalServerError(
        body: jsonEncode({'error': 'Failed to publish events to relay'}),
        headers: {'content-type': 'application/json'},
      );
    }

    print('🧹 Cleaning up temporary files...');

    // Clean up
    await File(session.apkPath).delete();
    sessions.remove(sessionId);

    print('🎉 Publishing completed successfully!');

    return Response.ok(
      jsonEncode({
        'success': true,
        'message':
            'APK successfully published to Zapstore!\n✅ Published to relay.zapstore.dev'
      }),
      headers: {'content-type': 'application/json'},
    );
  } catch (e, stackTrace) {
    print('❌ Publish error: $e');
    print('Stack trace: $stackTrace');
    return Response.internalServerError(
      body: jsonEncode({'error': 'Publishing failed: $e'}),
      headers: {'content-type': 'application/json'},
    );
  }
}

String _createYamlConfig(String? repository, String apkPath, String? iconUrl,
    String? description, String? license) {
  final config = <String, dynamic>{
    'assets': [apkPath],
  };

  if (repository != null && repository.isNotEmpty) {
    config['repository'] = repository;
  }
  if (iconUrl != null && iconUrl.isNotEmpty) {
    config['icon'] = iconUrl;
  }
  if (description != null && description.isNotEmpty) {
    config['description'] = description;
  }
  if (license != null && license.isNotEmpty) {
    config['license'] = license;
  }

  // Convert to YAML string manually for simple structure
  final buffer = StringBuffer();
  if (repository != null && repository.isNotEmpty) {
    buffer.writeln('repository: "$repository"');
  }
  if (iconUrl != null && iconUrl.isNotEmpty) {
    buffer.writeln('icon: "$iconUrl"');
  }
  if (description != null && description.isNotEmpty) {
    buffer.writeln('description: "$description"');
  }
  if (license != null && license.isNotEmpty) {
    buffer.writeln('license: "$license"');
  }
  buffer.writeln('assets:');
  buffer.writeln('  - "$apkPath"');

  return buffer.toString();
}

Future<bool> _publishToRelay(List<Map<String, dynamic>> signedEvents) async {
  try {
    // Publish each event individually via stdin to nak
    for (int i = 0; i < signedEvents.length; i++) {
      final event = signedEvents[i];
      final eventJson = jsonEncode(event);

      print('📡 Publishing event ${i + 1}/${signedEvents.length} to relay...');

      // Use nak event with stdin: echo (event) | nak event relay.zapstore.dev
      final process =
          await Process.start('nak', ['event', 'wss://relay.zapstore.dev']);

      // Send event JSON to stdin
      process.stdin.writeln(eventJson);
      await process.stdin.close();

      final exitCode = await process.exitCode;
      final stdout = await process.stdout.transform(utf8.decoder).join();
      final stderr = await process.stderr.transform(utf8.decoder).join();

      if (exitCode != 0) {
        print('❌ Failed to publish event ${i + 1}: $stderr');
        return false;
      }

      print('✅ Event ${i + 1} published: $stdout');
    }

    print('✅ All events published to relay successfully!');
    return true;
  } catch (e) {
    print('❌ Relay publish error: $e');
    return false;
  }
}

String _generateSessionId() {
  return DateTime.now().millisecondsSinceEpoch.toString() +
      (DateTime.now().microsecond % 1000).toString();
}
