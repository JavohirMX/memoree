# App Store Metadata & Submission Package

This document contains ready-to-use metadata for App Store Connect submission.

> [!IMPORTANT]
> **Guideline 2.3.8 / 4.1 Notice:** Do NOT use competitor trademark names (such as "BeReal") in the public title, subtitle, keywords, or description. Apple will reject submissions with competitor trademarks.

---

## 1. App Store Connect Listing Details

### App Information
- **App Name:** Memoree - Daily Moments *(24 / 30 chars)*
  - The unqualified name **Memoree** is already registered (a wedding booth app and Memoree AI). App Store Connect rejects it. Do not file a trademark claim. The name on the Home Screen stays Memoree; only the store name has to differ.
- **Subtitle:** Private daily photo journal *(27 / 30 chars)*
- **Primary Category:** Photo & Video
- **Secondary Category (Optional):** Lifestyle
- **Bundle ID:** `com.javohirmx.memoree`
- **SKU:** `memoree-ios-001`

### Pricing & Availability
- **Price:** Free
- **Availability:** All countries and regions (or select preferred regions)

### App Privacy (Nutrition Label)
- **Data Collection:** **Data Not Collected**
  - Select "No, we do not collect data from this app".
  - Memoree makes zero network calls and stores all media in the user's Apple Photos library.

---

## 2. Description & Promotional Text

### Promotional Text *(Up to 170 characters)*
> Capture spontaneous dual-camera moments every day. Zero social feed, zero accounts, zero cloud storage — completely private and saved directly to your Photos.

### Description *(Up to 4,000 characters)*
```markdown
Memoree is a daily photo journal built for spontaneity, authenticity, and complete personal privacy.

Capture both sides of your day in an instant: the scene in front of you and your reaction, taken sequentially with the rear and front cameras. No filters, no social feed, no algorithms, and no public profile. Just you and your memories.

KEY FEATURES:

• DUAL-CAMERA CAPTURE
Capture your surroundings and yourself in one seamless moment. Frame the scene, and Memoree instantly captures the other side.

• ZERO SOCIAL PRESSURE
No follower counts, no likes, no comments, and no public feed. Your memories are meant for you, not an audience.

• 100% PRIVATE & OFFLINE-FIRST
Memoree has no accounts, no logins, and no remote servers. It makes zero network requests. The app functions completely in Airplane Mode.

• DIRECT TO PHOTOS
Every moment you capture is saved directly to your device's Photos library with add-only access. Memoree never reads, scans, or deletes anything from your existing photo library.

• OPTIONAL BEHIND THE SCENES (BTS)
Add a short video clip with ambient sound to bring your daily photograph to life.

• ARCHIVE & STREAKS
Browse your memories through a monthly calendar, look back on past years with the Same-Day Flipbook, and track your daily consistency.

• LOCK SCREEN & HOME SCREEN WIDGETS
Check your daily capture status and streak at a glance without even opening the app.

Simple. Spontaneous. Yours.
```

### Keywords *(Up to 100 characters)*
```
photo journal,dual camera,daily moment,camera roll,spontaneous,offline,private diary,flashback
```
*(93 / 100 characters)*

---

## 3. URLs
- **Privacy Policy URL:** `https://javohirmx.github.io/memoree/privacy` *(point to docs/PRIVACY_POLICY.md)*
- **Support URL:** `https://github.com/javohirmx/memoree` *(or your website/email)*
- **Marketing URL (Optional):** `https://github.com/javohirmx/memoree`

---

## 4. App Review Information (Reviewer Notes)

Provide this note to Apple App Review in App Store Connect:

```text
Review Notes:

Memoree is a standalone, offline-first personal photo journal.

- Accounts & Authentication: None. The app does not require a user account, sign-in, or internet connection.
- Camera & Permissions: The app uses the camera to capture sequential rear and front photos. Reviewers can tap the shutter button at any time to take a capture.
- Photo Library: The app uses Apple's add-only permission (PHAccessLevel.addOnly) to save captured dual photos directly to the user's device photo library.
- Behind the Scenes (BTS): Capturing optional ambient video/audio can be tested in Settings.
- Notifications: The app schedules a local on-device notification once per day within the user's configured notification window (default 09:00 - 23:00).
- Contact: For any questions during review, please contact support at javohirmx@gmail.com.
```

---

## 5. Required Screenshots Checklist

Screenshots must be provided for the following display sizes (captured in Dark Mode, matching Memoree's canvas):

1. **6.9" / 6.7" iPhone Display** (iPhone 16 Pro Max / 15 Pro Max):
   - Resolution: `1320 x 2868` or `1290 x 2796` pixels.
2. **6.5" / 5.5" iPhone Display** (if targeting older device families, or use 6.7" auto-scaling).

### Recommended 5-Screen Storyboard:
1. **Screen 1 (Today / Dual Capture):** Real dual-camera preview showing scene + inset selfie. Headline: *"Capture both sides of your moment"*.
2. **Screen 2 (Single Moment Detail / BTS):** Reviewing a captured moment with the BTS playback badge. Headline: *"Authentic, unfiltered memories"*.
3. **Screen 3 (Archive Calendar):** The monthly grid showing captured days and thumbnails. Headline: *"Your year in daily photographs"*.
4. **Screen 4 (Stats & Streaks):** Streak counter and capture insights. Headline: *"Build your personal consistency"*.
5. **Screen 5 (Privacy & Offline):** Settings showing zero accounts, add-only photos, and complete offline privacy. Headline: *"No feed. No accounts. 100% private"*.
