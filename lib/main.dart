import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dart_appwrite/dart_appwrite.dart';
import 'package:pointycastle/export.dart';

final String? endpoint = Platform.environment['APPWRITE_ENDPOINT'];
final String? projectId = Platform.environment['APPWRITE_FUNCTION_PROJECT_ID'];
final String? apiKey = Platform.environment['APPWRITE_API_KEY'];
final String? databaseId = Platform.environment['DATABASE_ID'];
final String? usersCollection = Platform.environment['USERS_COLLECTION'];
final String? firebaseServiceAccount =
    Platform.environment['FIREBASE_SERVICE_ACCOUNT'];

Client _adminClient() => Client()
  ..setEndpoint(endpoint ?? 'https://fra.cloud.appwrite.io/v1')
  ..setProject(projectId ?? '')
  ..setKey(apiKey ?? '');

/// Helper to return JSON response
dynamic _jsonResponse(dynamic context, Map<String, dynamic> data,
    {int statusCode = 200}) {
  return context.res.send(
    jsonEncode(data),
    statusCode,
    {'content-type': 'application/json'},
  );
}

/// Parse RSA private key from PEM format
RSAPrivateKey _parsePrivateKeyFromPem(String pem) {
  // Remove PEM headers/footers and decode
  final lines = pem
      .replaceAll('-----BEGIN PRIVATE KEY-----', '')
      .replaceAll('-----END PRIVATE KEY-----', '')
      .replaceAll('-----BEGIN RSA PRIVATE KEY-----', '')
      .replaceAll('-----END RSA PRIVATE KEY-----', '')
      .replaceAll('\n', '')
      .replaceAll('\r', '');

  final bytes = base64.decode(lines);

  // Parse PKCS#8 format
  final asn1Parser = ASN1Parser(Uint8List.fromList(bytes));
  final topLevelSeq = asn1Parser.nextObject() as ASN1Sequence;

  // PKCS#8 format: SEQ { version, algorithm, privateKey }
  ASN1Object privateKeyOctet;

  if (topLevelSeq.elements!.length == 3) {
    // PKCS#8 format
    privateKeyOctet = topLevelSeq.elements![2];
    final privateKeyParser =
        ASN1Parser((privateKeyOctet as ASN1OctetString).octets);
    final privateKeySeq = privateKeyParser.nextObject() as ASN1Sequence;
    return _parseRsaPrivateKeySequence(privateKeySeq);
  } else {
    // PKCS#1 format (raw RSA key)
    return _parseRsaPrivateKeySequence(topLevelSeq);
  }
}

RSAPrivateKey _parseRsaPrivateKeySequence(ASN1Sequence seq) {
  final modulus = (seq.elements![1] as ASN1Integer).integer!;
  final privateExponent = (seq.elements![3] as ASN1Integer).integer!;
  final p = (seq.elements![4] as ASN1Integer).integer!;
  final q = (seq.elements![5] as ASN1Integer).integer!;

  return RSAPrivateKey(modulus, privateExponent, p, q);
}

/// Sign data with RSA-SHA256
String _rsaSign(String data, RSAPrivateKey privateKey) {
  final signer = RSASigner(SHA256Digest(), '0609608648016503040201');
  signer.init(true, PrivateKeyParameter<RSAPrivateKey>(privateKey));

  final dataBytes = Uint8List.fromList(utf8.encode(data));
  final signature = signer.generateSignature(dataBytes) as RSASignature;

  return base64Url.encode(signature.bytes).replaceAll('=', '');
}

/// Get OAuth2 access token from service account using JWT
Future<String?> _getAccessToken(
    Map<String, dynamic> serviceAccount, dynamic context) async {
  try {
    final clientEmail = serviceAccount['client_email'] as String;
    final privateKeyPem = serviceAccount['private_key'] as String;
    final tokenUri = serviceAccount['token_uri'] as String? ??
        'https://oauth2.googleapis.com/token';

    context.log('🔑 Creating JWT for: $clientEmail');

    final privateKey = _parsePrivateKeyFromPem(privateKeyPem);
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

    final headerB64 =
        base64Url.encode(utf8.encode(jsonEncode(header))).replaceAll('=', '');
    final payloadB64 =
        base64Url.encode(utf8.encode(jsonEncode(payload))).replaceAll('=', '');
    final signatureInput = '$headerB64.$payloadB64';

    // Sign with RSA-SHA256 using pointycastle
    final signature = _rsaSign(signatureInput, privateKey);
    final jwt = '$signatureInput.$signature';

    context.log('📝 JWT created, exchanging for access token...');

    // Exchange JWT for access token
    final httpClient = HttpClient();
    final request = await httpClient.postUrl(Uri.parse(tokenUri));
    request.headers.set('Content-Type', 'application/x-www-form-urlencoded');

    final requestBody =
        'grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=$jwt';
    request.write(requestBody);

    final response = await request.close();
    final responseBody = await response.transform(utf8.decoder).join();

    if (response.statusCode == 200) {
      final data = jsonDecode(responseBody) as Map<String, dynamic>;
      context.log('✅ Access token obtained successfully');
      return data['access_token'] as String?;
    } else {
      context.error(
          '❌ Token exchange failed (${response.statusCode}): $responseBody');
      return null;
    }
  } catch (e, stack) {
    context.error('❌ Error getting access token: $e');
    context.error('Stack: $stack');
    return null;
  }
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
    final serviceAccount =
        jsonDecode(firebaseServiceAccount!) as Map<String, dynamic>;
    final firebaseProjectId = serviceAccount['project_id'] as String?;

    if (firebaseProjectId == null) {
      context.error('❌ project_id not found in service account');
      return false;
    }

    context.log('🔔 Sending to project: $firebaseProjectId');

    // Get access token using Google Auth
    final accessToken = await _getAccessToken(serviceAccount, context);
    if (accessToken == null) {
      context.error('❌ Failed to get access token');
      return false;
    }

    final httpClient = HttpClient();
    final request = await httpClient.postUrl(
      Uri.parse(
          'https://fcm.googleapis.com/v1/projects/$firebaseProjectId/messages:send'),
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
  } catch (e, stack) {
    context.error('❌ FCM Error: $e');
    context.error('Stack: $stack');
    return false;
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
    context.log('════════════════════════════════════════');
    context.log('🔔 Push Notifications Function started');
    context.log('════════════════════════════════════════');

    // Log environment variables (for debugging)
    context.log('📋 Environment check:');
    context.log('   - DATABASE_ID: ${databaseId ?? "NOT SET"}');
    context.log('   - USERS_COLLECTION: ${usersCollection ?? "NOT SET"}');
    context.log(
        '   - FIREBASE_SERVICE_ACCOUNT: ${firebaseServiceAccount != null ? "SET (${firebaseServiceAccount!.length} chars)" : "NOT SET"}');

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

    context.log('📦 Event data keys: ${eventData.keys.toList()}');

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
    if (event.contains('users') && event.contains('update')) {
      final userId = eventData['\$id'] ?? '';
      final kycStatus = eventData['kyc_status'] ?? '';
      final fcmToken = eventData['fcm_token'] ?? '';

      context.log('════════════════════════════════════════');
      context.log('👤 USER UPDATE DETECTED');
      context.log('   - User ID: $userId');
      context.log('   - KYC Status: $kycStatus');
      context
          .log('   - FCM Token: ${fcmToken.isNotEmpty ? "present" : "MISSING"}');
      context.log('════════════════════════════════════════');

      if (fcmToken.isEmpty) {
        context.log('⚠️ No FCM token for user - cannot send notification');
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
        context.log('🎉 KYC APPROVED - Preparing notification');
        notifTitle = 'تهانينا! 🎉';
        notifBody = 'تم التحقق من حسابك بنجاح! يمكنك الآن استخدام التطبيق';
        data = {'type': 'kyc_approved', 'userId': userId};
      }
      // Check for KYC rejection
      else if (kycStatus == 'rejected') {
        context.log('❌ KYC REJECTED - Preparing notification');
        notifTitle = 'تم رفض الطلب ❌';
        notifBody = 'نأسف، تم رفض طلب التحقق. يرجى المحاولة مرة أخرى';
        data = {'type': 'kyc_rejected', 'userId': userId};
      } else {
        context.log('ℹ️ KYC status is "$kycStatus" - no notification needed');
      }

      if (notifTitle != null && notifBody != null) {
        context.log('📤 Sending KYC notification...');
        context.log('   Title: $notifTitle');
        context.log('   Body: $notifBody');

        final success = await sendFcmNotification(
          fcmToken: fcmToken,
          title: notifTitle,
          body: notifBody,
          data: data,
          context: context,
        );

        context.log('════════════════════════════════════════');
        context.log(
            '📱 KYC notification result: ${success ? "SUCCESS ✅" : "FAILED ❌"}');
        context.log('════════════════════════════════════════');

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
    if (event.contains('ads') && event.contains('create')) {
      final adTitle = eventData['title'] ?? 'إعلان جديد';
      final chickenType = eventData['chicken_type'] ?? '';
      final count = eventData['count'] ?? 0;
      final wilaya = eventData['wilaya'] ?? '';
      final sellerId = eventData['user_id'] ?? '';

      context.log('════════════════════════════════════════');
      context.log('📢 NEW AD CREATED');
      context.log('   - Title: $adTitle');
      context.log('   - Seller: $sellerId');
      context.log('════════════════════════════════════════');

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
        final buyersToNotify =
            buyers.documents.where((b) => b.$id != sellerId).toList();

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

    context.log('ℹ️ Event not matched - no action taken');
    context.log('   Received event: $event');
    context.log('   Expected: event containing "users" + "update" OR "ads" + "create"');

    return _jsonResponse(context, {
      'success': true,
      'message': 'Event processed (no action taken)',
      'event': event,
    });
  } catch (e, stack) {
    context.error('❌ Function error: $e');
    context.error('Stack trace: $stack');
    return _jsonResponse(
        context,
        {
          'success': false,
          'error': e.toString(),
        },
        statusCode: 500);
  }
}
