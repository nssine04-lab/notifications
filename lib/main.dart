import 'dart:convert';
import 'dart:io';
import 'package:dart_appwrite/dart_appwrite.dart';

final String? endpoint = Platform.environment['APPWRITE_ENDPOINT'];
final String? projectId = Platform.environment['APPWRITE_FUNCTION_PROJECT_ID'];
final String? apiKey = Platform.environment['APPWRITE_API_KEY'];
final String? databaseId = Platform.environment['DATABASE_ID'];
final String? usersCollection = Platform.environment['USERS_COLLECTION'];
final String? firebaseServiceAccount = Platform.environment['FIREBASE_SERVICE_ACCOUNT'];

Client _adminClient() => Client()
  ..setEndpoint(endpoint ?? 'https://fra.cloud.appwrite.io/v1')
  ..setProject(projectId ?? '')
  ..setKey(apiKey ?? '');

/// Helper to return JSON response
dynamic _jsonResponse(dynamic context, Map<String, dynamic> data, {int statusCode = 200}) {
  return context.res.send(
    jsonEncode(data),
    statusCode,
    {'content-type': 'application/json'},
  );
}

/// Send FCM notification using HTTP v1 API with service account
Future<bool> sendFcmNotification({
  required String fcmToken,
  required String title,
  required String body,
  Map<String, String>? data,
  required dynamic context,
}) async {
  if (firebaseServiceAccount == null || firebaseServiceAccount!.isEmpty) {
    context.error('❌ FIREBASE_SERVICE_ACCOUNT not set');
    return false;
  }

  try {
    final serviceAccount = jsonDecode(firebaseServiceAccount!) as Map<String, dynamic>;
    final firebaseProjectId = serviceAccount['project_id'] as String?;
    
    if (firebaseProjectId == null) {
      context.error('❌ project_id not found in service account');
      return false;
    }

    // Get access token using Google Auth
    final accessToken = await _getAccessToken(serviceAccount, context);
    if (accessToken == null) {
      context.error('❌ Failed to get access token');
      return false;
    }

    final httpClient = HttpClient();
    final request = await httpClient.postUrl(
      Uri.parse('https://fcm.googleapis.com/v1/projects/$firebaseProjectId/messages:send'),
    );

    request.headers.set('Content-Type', 'application/json');
    request.headers.set('Authorization', 'Bearer $accessToken');

    final payload = {
      'message': {
        'token': fcmToken,
        'notification': {
          'title': title,
          'body': body,
        },
        'data': data?.map((k, v) => MapEntry(k, v.toString())) ?? {},
        'android': {
          'priority': 'high',
          'notification': {
            'channel_id': 'adjaj_notifications',
            'sound': 'default',
          },
        },
      },
    };

    request.write(jsonEncode(payload));
    final response = await request.close();
    final responseBody = await response.transform(utf8.decoder).join();

    context.log('📨 FCM Response (${response.statusCode}): $responseBody');

    return response.statusCode == 200;
  } catch (e) {
    context.error('❌ FCM Error: $e');
    return false;
  }
}

/// Get OAuth2 access token from service account using JWT
Future<String?> _getAccessToken(Map<String, dynamic> serviceAccount, dynamic context) async {
  try {
    final clientEmail = serviceAccount['client_email'] as String;
    final privateKeyPem = serviceAccount['private_key'] as String;
    final tokenUri = serviceAccount['token_uri'] as String? ?? 'https://oauth2.googleapis.com/token';

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    // Create JWT header
    final header = {
      'alg': 'RS256',
      'typ': 'JWT',
    };

    // Create JWT payload
    final payload = {
      'iss': clientEmail,
      'scope': 'https://www.googleapis.com/auth/firebase.messaging',
      'aud': tokenUri,
      'iat': now,
      'exp': now + 3600,
    };

    final headerB64 = base64Url.encode(utf8.encode(jsonEncode(header))).replaceAll('=', '');
    final payloadB64 = base64Url.encode(utf8.encode(jsonEncode(payload))).replaceAll('=', '');
    final signatureInput = '$headerB64.$payloadB64';

    // Sign with RSA-SHA256 using openssl
    final signature = await _rsaSign(signatureInput, privateKeyPem);
    if (signature == null) {
      context.error('❌ Failed to sign JWT');
      return null;
    }

    final jwt = '$signatureInput.$signature';

    // Exchange JWT for access token
    final httpClient = HttpClient();
    final request = await httpClient.postUrl(Uri.parse(tokenUri));
    request.headers.set('Content-Type', 'application/x-www-form-urlencoded');

    final requestBody = 'grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=$jwt';
    request.write(requestBody);

    final response = await request.close();
    final responseBody = await response.transform(utf8.decoder).join();

    if (response.statusCode == 200) {
      final data = jsonDecode(responseBody) as Map<String, dynamic>;
      return data['access_token'] as String?;
    } else {
      context.error('❌ Token exchange failed (${response.statusCode}): $responseBody');
      return null;
    }
  } catch (e) {
    context.error('❌ Error getting access token: $e');
    return null;
  }
}

/// Sign data with RSA-SHA256 using private key via openssl
Future<String?> _rsaSign(String data, String privateKeyPem) async {
  try {
    final tempDir = Directory.systemTemp;
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final keyFile = File('${tempDir.path}/pk_$timestamp.pem');
    final dataFile = File('${tempDir.path}/data_$timestamp.txt');
    final sigFile = File('${tempDir.path}/sig_$timestamp.bin');

    try {
      await keyFile.writeAsString(privateKeyPem);
      await dataFile.writeAsString(data);

      // Use openssl to sign
      final result = await Process.run('openssl', [
        'dgst',
        '-sha256',
        '-sign',
        keyFile.path,
        '-out',
        sigFile.path,
        dataFile.path,
      ]);

      if (result.exitCode != 0) {
        return null;
      }

      final sigBytes = await sigFile.readAsBytes();
      return base64Url.encode(sigBytes).replaceAll('=', '');
    } finally {
      // Cleanup temp files
      if (await keyFile.exists()) await keyFile.delete();
      if (await dataFile.exists()) await dataFile.delete();
      if (await sigFile.exists()) await sigFile.delete();
    }
  } catch (e) {
    return null;
  }
}

/// Send FCM notification to multiple tokens
Future<int> sendFcmToMany({
  required List<String> fcmTokens,
  required String title,
  required String body,
  Map<String, String>? data,
  required dynamic context,
}) async {
  int successCount = 0;

  for (final token in fcmTokens) {
    final success = await sendFcmNotification(
      fcmToken: token,
      title: title,
      body: body,
      data: data,
      context: context,
    );
    if (success) successCount++;
  }

  return successCount;
}

// Entry point for Appwrite Function
Future<dynamic> main(final context) async {
  try {
    context.log('🔔 Push Notifications Function started');

    final event = context.req.headers['x-appwrite-event'] ?? '';
    context.log('📨 Event: $event');

    // Parse event data
    Map<String, dynamic> eventData = {};
    final body = context.req.body;

    if (body is String && body.isNotEmpty) {
      eventData = jsonDecode(body) as Map<String, dynamic>;
    } else if (body is Map) {
      eventData = Map<String, dynamic>.from(body);
    }

    context.log('📦 Data keys: ${eventData.keys.toList()}');

    // Validate environment variables
    if (databaseId == null || usersCollection == null) {
      context.error('❌ DATABASE_ID or USERS_COLLECTION not set');
      return _jsonResponse(context, {
        'success': false,
        'error': 'Missing environment variables',
      });
    }

    if (firebaseServiceAccount == null) {
      context.error('❌ FIREBASE_SERVICE_ACCOUNT not set');
      return _jsonResponse(context, {
        'success': false,
        'error': 'FIREBASE_SERVICE_ACCOUNT not set',
      });
    }

    final client = _adminClient();
    final databases = Databases(client);

    // ═══════════════════════════════════════════════════════
    // CASE 1: KYC Status Changed (User document updated)
    // ═══════════════════════════════════════════════════════
    if (event.contains('collections.users.documents') && event.contains('.update')) {
      final userId = eventData['\$id'] ?? '';
      final kycStatus = eventData['kyc_status'] ?? '';
      final fcmToken = eventData['fcm_token'] ?? '';

      context.log('👤 User update: $userId, KYC: $kycStatus, FCM: ${fcmToken.isNotEmpty ? "present" : "missing"}');

      if (fcmToken.isEmpty) {
        context.log('⚠️ No FCM token for user');
        return _jsonResponse(context, {
          'success': true,
          'message': 'No FCM token',
        });
      }

      String? notifTitle;
      String? notifBody;
      Map<String, String>? data;

      // Check for KYC approval (status changed to 'approved')
      if (kycStatus == 'approved') {
        notifTitle = 'تهانينا! 🎉';
        notifBody = 'تم التحقق من حسابك بنجاح! يمكنك الآن استخدام التطبيق';
        data = {'type': 'kyc_approved', 'userId': userId};
      }
      // Check for KYC rejection
      else if (kycStatus == 'rejected') {
        notifTitle = 'تم رفض الطلب ❌';
        notifBody = 'نأسف، تم رفض طلب التحقق. يرجى المحاولة مرة أخرى';
        data = {'type': 'kyc_rejected', 'userId': userId};
      }

      if (notifTitle != null && notifBody != null) {
        context.log('📤 Sending KYC notification...');
        final success = await sendFcmNotification(
          fcmToken: fcmToken,
          title: notifTitle,
          body: notifBody,
          data: data,
          context: context,
        );

        context.log('✅ KYC notification result: $success');
        return _jsonResponse(context, {
          'success': true,
          'message': 'KYC notification sent',
          'sent': success,
        });
      }

      return _jsonResponse(context, {
        'success': true,
        'message': 'User update processed, no notification needed',
      });
    }

    // ═══════════════════════════════════════════════════════
    // CASE 2: New Ad Created - Notify all approved buyers
    // ═══════════════════════════════════════════════════════
    if (event.contains('collections.ads.documents') && event.contains('.create')) {
      final adTitle = eventData['title'] ?? 'إعلان جديد';
      final chickenType = eventData['chicken_type'] ?? '';
      final count = eventData['count'] ?? 0;
      final wilaya = eventData['wilaya'] ?? '';
      final sellerId = eventData['user_id'] ?? '';

      context.log('📢 New ad created: $adTitle by $sellerId');

      // Get all approved buyers with FCM tokens
      try {
        final buyers = await databases.listDocuments(
          databaseId: databaseId!,
          collectionId: usersCollection!,
          queries: [
            Query.equal('role', 'buyer'),
            Query.equal('kyc_status', 'approved'),
            Query.isNotNull('fcm_token'),
          ],
        );

        // Filter out the seller
        final buyersToNotify = buyers.documents
            .where((b) => b.$id != sellerId)
            .toList();

        context.log('📱 Found ${buyersToNotify.length} buyers to notify');

        if (buyersToNotify.isEmpty) {
          return _jsonResponse(context, {
            'success': true,
            'message': 'No buyers to notify',
          });
        }

        final tokens = buyersToNotify
            .map((b) => b.data['fcm_token'] as String?)
            .where((t) => t != null && t.isNotEmpty)
            .cast<String>()
            .toList();

        if (tokens.isEmpty) {
          return _jsonResponse(context, {
            'success': true,
            'message': 'No valid tokens',
          });
        }

        final notifTitle = 'إعلان جديد 🐔';
        final notifBody = '$adTitle - $count $chickenType في $wilaya';

        final successCount = await sendFcmToMany(
          fcmTokens: tokens,
          title: notifTitle,
          body: notifBody,
          data: {
            'type': 'new_ad',
            'adId': eventData['\$id'] ?? '',
            'title': adTitle,
          },
          context: context,
        );

        context.log('✅ Sent $successCount/${tokens.length} notifications');

        return _jsonResponse(context, {
          'success': true,
          'message': 'Notified $successCount buyers about new ad',
          'total': tokens.length,
          'sent': successCount,
        });
      } catch (e) {
        context.error('❌ Error querying buyers: $e');
        return _jsonResponse(context, {
          'success': false,
          'error': 'Failed to query buyers: $e',
        });
      }
    }

    return _jsonResponse(context, {
      'success': true,
      'message': 'Event processed (no action taken)',
    });
  } catch (e, stack) {
    context.error('❌ Function error: $e');
    context.error('Stack trace: $stack');
    return _jsonResponse(context, {
      'success': false,
      'error': e.toString(),
    }, statusCode: 500);
  }
}
