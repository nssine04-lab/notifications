import 'dart:convert';
import 'dart:io';
import 'package:dart_appwrite/dart_appwrite.dart';

final String? endpoint = Platform.environment['APPWRITE_ENDPOINT'];
final String? projectId = Platform.environment['APPWRITE_FUNCTION_PROJECT_ID'];
final String? apiKey = Platform.environment['APPWRITE_API_KEY'];
final String? databaseId = Platform.environment['DATABASE_ID'];
final String? usersCollection = Platform.environment['USERS_COLLECTION'];
final String? firebaseServerKey = Platform.environment['FIREBASE_SERVER_KEY'];

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

/// Send FCM notification using HTTP v1 API
Future<bool> sendFcmNotification({
  required String fcmToken,
  required String title,
  required String body,
  Map<String, String>? data,
  required dynamic context,
}) async {
  if (firebaseServerKey == null || firebaseServerKey!.isEmpty) {
    context.error('❌ FIREBASE_SERVER_KEY not set');
    return false;
  }

  try {
    final httpClient = HttpClient();
    final request = await httpClient.postUrl(
      Uri.parse('https://fcm.googleapis.com/fcm/send'),
    );

    request.headers.set('Content-Type', 'application/json');
    request.headers.set('Authorization', 'key=$firebaseServerKey');

    final payload = {
      'to': fcmToken,
      'notification': {
        'title': title,
        'body': body,
        'sound': 'default',
      },
      'data': data ?? {},
      'priority': 'high',
      'android': {
        'priority': 'high',
        'notification': {
          'channel_id': 'adjaj_notifications',
          'sound': 'default',
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

/// Send FCM notification to multiple tokens
Future<int> sendFcmToMany({
  required List<String> fcmTokens,
  required String title,
  required String body,
  Map<String, String>? data,
  required dynamic context,
}) async {
  if (firebaseServerKey == null || firebaseServerKey!.isEmpty) {
    context.error('❌ FIREBASE_SERVER_KEY not set');
    return 0;
  }

  int successCount = 0;
  
  // FCM legacy API supports up to 1000 tokens per request
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

    context.log('📦 Data: ${jsonEncode(eventData)}');

    // Validate environment variables
    if (databaseId == null || usersCollection == null) {
      context.error('❌ DATABASE_ID or USERS_COLLECTION not set');
      return _jsonResponse(context, {
        'success': false,
        'error': 'Missing environment variables',
      });
    }

    final client = _adminClient();
    final databases = Databases(client);

    // ═══════════════════════════════════════════════════════
    // CASE 1: KYC Status Changed (User document updated)
    // ═══════════════════════════════════════════════════════
    if (event.contains('collections.$usersCollection.documents') && 
        event.contains('.update')) {
      
      final userId = eventData['\$id'] ?? '';
      final kycStatus = eventData['kyc_status'] ?? '';
      final fcmToken = eventData['fcm_token'] ?? '';

      context.log('👤 User update: $userId, KYC: $kycStatus');

      if (fcmToken.isEmpty) {
        context.log('⚠️ No FCM token for user');
        return _jsonResponse(context, {
          'success': true,
          'message': 'No FCM token',
        });
      }

      String? title;
      String? body;
      Map<String, String>? data;

      // Check for KYC approval (status changed to 'approved')
      if (kycStatus == 'approved') {
        title = 'تهانينا! 🎉';
        body = 'تم التحقق من حسابك بنجاح! يمكنك الآن استخدام التطبيق';
        data = {'type': 'kyc_approved', 'userId': userId};
      } 
      // Check for KYC rejection
      else if (kycStatus == 'rejected') {
        title = 'تم رفض الطلب ❌';
        body = 'نأسف، تم رفض طلب التحقق. يرجى المحاولة مرة أخرى';
        data = {'type': 'kyc_rejected', 'userId': userId};
      }

      if (title != null && body != null) {
        final success = await sendFcmNotification(
          fcmToken: fcmToken,
          title: title,
          body: body,
          data: data,
          context: context,
        );

        context.log('✅ KYC notification sent: $success');
        return _jsonResponse(context, {
          'success': true,
          'message': 'KYC notification sent',
          'sent': success,
        });
      }
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
