const sdk = require('node-appwrite');
const admin = require('firebase-admin');

let firebaseInitialized = false;

function initializeFirebase(log) {
  if (firebaseInitialized) return true;
  
  try {
    const serviceAccount = JSON.parse(process.env.FIREBASE_SERVICE_ACCOUNT);
    admin.initializeApp({
      credential: admin.credential.cert(serviceAccount),
    });
    firebaseInitialized = true;
    log('✅ Firebase initialized');
    return true;
  } catch (error) {
    log('❌ Failed to initialize Firebase: ' + error.message);
    return false;
  }
}

async function sendNotification(token, title, body, data = {}) {
  if (!token) return null;
  
  const message = {
    token: token,
    notification: { title, body },
    data: data,
    android: {
      priority: 'high',
      notification: {
        sound: 'default',
        channelId: 'adjaj_notifications',
      }
    },
    apns: {
      payload: {
        aps: {
          sound: 'default',
          badge: 1,
        }
      }
    }
  };

  return await admin.messaging().send(message);
}

async function sendNotificationToMany(tokens, title, body, data = {}) {
  const validTokens = tokens.filter(t => t && t.length > 0);
  if (validTokens.length === 0) return null;
  
  const message = {
    tokens: validTokens,
    notification: { title, body },
    data: data,
    android: {
      priority: 'high',
      notification: {
        sound: 'default',
        channelId: 'adjaj_notifications',
      }
    },
    apns: {
      payload: {
        aps: {
          sound: 'default',
          badge: 1,
        }
      }
    }
  };

  return await admin.messaging().sendEachForMulticast(message);
}

module.exports = async ({ req, res, log, error }) => {
  // Initialize Appwrite client
  const client = new sdk.Client()
    .setEndpoint(process.env.APPWRITE_ENDPOINT)
    .setProject(process.env.APPWRITE_FUNCTION_PROJECT_ID)
    .setKey(process.env.APPWRITE_API_KEY);

  const databases = new sdk.Databases(client);

  try {
    const event = req.headers['x-appwrite-event'] || '';
    const eventData = req.body;
    
    log('📨 Event: ' + event);
    log('📦 Data: ' + JSON.stringify(eventData));

    if (!initializeFirebase(log)) {
      return res.json({ success: false, error: 'Firebase not initialized' });
    }

    const databaseId = process.env.DATABASE_ID;
    const usersCollection = process.env.USERS_COLLECTION;

    // ═══════════════════════════════════════════════════════
    // CASE 1: KYC Status Changed
    // ═══════════════════════════════════════════════════════
    if (event.includes('collections.' + usersCollection + '.documents') && event.includes('.update')) {
      const userId = eventData.$id;
      const kycStatus = eventData.kyc_status;
      const fcmToken = eventData.fcm_token;

      log('👤 User update: ' + userId + ', KYC: ' + kycStatus);

      if (!fcmToken) {
        log('⚠️ No FCM token for user');
        return res.json({ success: true, message: 'No FCM token' });
      }

      let notification = null;

      if (kycStatus === 'verified') {
        notification = {
          title: 'تهانينا! 🎉',
          body: 'تم التحقق من حسابك بنجاح! يمكنك الآن استخدام التطبيق',
          data: { type: 'kyc_approved', userId: userId }
        };
      } else if (kycStatus === 'rejected') {
        notification = {
          title: 'تم رفض الطلب ❌',
          body: 'نأسف، تم رفض طلب التحقق. يرجى المحاولة مرة أخرى',
          data: { type: 'kyc_rejected', userId: userId }
        };
      }

      if (notification) {
        const result = await sendNotification(fcmToken, notification.title, notification.body, notification.data);
        log('✅ KYC notification sent: ' + result);
        return res.json({ success: true, message: 'KYC notification sent' });
      }
    }

    // ═══════════════════════════════════════════════════════
    // CASE 2: New Ad Created - Notify all verified buyers
    // ═══════════════════════════════════════════════════════
    if (event.includes('collections.ads.documents') && event.includes('.create')) {
      const adTitle = eventData.title || 'إعلان جديد';
      const chickenType = eventData.chicken_type || '';
      const count = eventData.count || 0;
      const wilaya = eventData.wilaya || '';
      const sellerId = eventData.user_id;

      log('📢 New ad created: ' + adTitle + ' by ' + sellerId);

      // Get all verified buyers with FCM tokens
      const buyers = await databases.listDocuments(
        databaseId,
        usersCollection,
        [
          sdk.Query.equal('role', 'buyer'),
          sdk.Query.equal('kyc_status', 'verified'),
          sdk.Query.isNotNull('fcm_token'),
        ]
      );

      // Filter out the seller
      const buyersToNotify = buyers.documents.filter(b => b.$id !== sellerId);
      log('📱 Found ' + buyersToNotify.length + ' buyers to notify');

      if (buyersToNotify.length === 0) {
        return res.json({ success: true, message: 'No buyers to notify' });
      }

      const tokens = buyersToNotify
        .map(buyer => buyer.fcm_token)
        .filter(token => token && token.length > 0);

      if (tokens.length === 0) {
        return res.json({ success: true, message: 'No valid tokens' });
      }

      const title = 'إعلان جديد 🐔';
      const body = adTitle + ' - ' + count + ' ' + chickenType + ' في ' + wilaya;
      
      const result = await sendNotificationToMany(tokens, title, body, {
        type: 'new_ad',
        adId: eventData.$id,
        title: adTitle,
      });

      log('✅ Sent ' + result.successCount + ' notifications, ' + result.failureCount + ' failed');

      return res.json({ 
        success: true, 
        message: 'Notified ' + tokens.length + ' buyers about new ad' 
      });
    }

    return res.json({ success: true, message: 'Event processed' });

  } catch (err) {
    error('❌ Error: ' + err.message);
    return res.json({ success: false, error: err.message });
  }
};
