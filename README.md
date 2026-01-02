# Push Notifications Function

Appwrite Cloud Function for sending push notifications to users.

## Features

- ✅ KYC Approved notification
- ❌ KYC Rejected notification  
- 🐔 New Ad notification to all verified buyers

## Environment Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `APPWRITE_ENDPOINT` | Appwrite API endpoint | `https://fra.cloud.appwrite.io/v1` |
| `APPWRITE_API_KEY` | Appwrite API key with database read access | `your-api-key` |
| `DATABASE_ID` | Your database ID | `695534670020c39eb399` |
| `USERS_COLLECTION` | Users collection ID | `users` |
| `FIREBASE_SERVICE_ACCOUNT` | Firebase service account JSON | `{"type":"service_account",...}` |

## Events to Subscribe

In Appwrite Console, subscribe this function to:

```
databases.<DATABASE_ID>.collections.users.documents.*.update
databases.<DATABASE_ID>.collections.ads.documents.*.create
```

Replace `<DATABASE_ID>` with your actual database ID.

## Deployment

### Option 1: Appwrite CLI

```bash
appwrite deploy function
```

### Option 2: Manual Upload

1. Go to Appwrite Console > Functions
2. Create new function with Node.js 18.0 runtime
3. Upload this folder
4. Set environment variables
5. Subscribe to events

## Database Requirements

Your `users` collection must have:
- `fcm_token` (string, size 500) - for storing Firebase tokens
- `role` (string) - "buyer" or "seller"
- `kyc_status` (string) - "pending", "verified", or "rejected"

## Getting Firebase Service Account

1. Go to [Firebase Console](https://console.firebase.google.com)
2. Project Settings > Service Accounts
3. Click "Generate new private key"
4. Copy the entire JSON content as `FIREBASE_SERVICE_ACCOUNT` env variable
