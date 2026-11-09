# Privacy Policy for Memoree

**Effective Date:** October 14, 2026  
**Last Updated:** October 14, 2026  

Memoree ("we", "us", or "our") was built from the ground up on a simple principle: **your memories belong to you, and nobody else.**

Memoree has **no accounts, no remote servers, no analytics, and makes zero network requests**. All processing and storage occurs entirely on your device.

---

## 1. Information We Collect

**We collect zero personal data.**

- **No Personal Identifiers:** We do not ask for or collect names, email addresses, phone numbers, or usernames.
- **No Account Creation:** You do not create an account to use Memoree.
- **No Cloud Sync or Remote Storage:** Your photos, video clips, and metadata never leave your device.
- **No Analytics or Tracking:** We do not include any tracking frameworks, advertising identifiers (IDFA), crash reporting tools, or third-party SDKs. The app makes no network calls whatsoever.

---

## 2. On-Device Device Permissions & Usage

Memoree requests certain device permissions exclusively to provide core local features:

- **Camera (`NSCameraUsageDescription`):**  
  Used to capture your daily moment using the rear and front cameras sequentially. Captured images are processed in memory and saved directly to your device.
- **Photo Library Add-Only (`NSPhotoLibraryAddUsageDescription`):**  
  Used solely to save the moments you capture to your Apple Photos library. Memoree uses Apple's add-only permission model (`PHAccessLevel.addOnly`). It cannot view, read, or delete your existing photo library.
- **Microphone (`NSMicrophoneUsageDescription`) [Optional]:**  
  Used exclusively when the optional Behind the Scenes (BTS) feature is enabled to capture a few seconds of ambient audio with your moment. If declined, BTS clips are recorded silently.
- **Location (`NSLocationWhenInUseUsageDescription`) [Optional]:**  
  If you choose to enable location tagging, coordinates are embedded directly into the photo's standard EXIF metadata and local app storage. Coordinates are never transmitted off your device and are never resolved to geographic place names via remote geocoding.
- **Notifications (`UNUserNotificationCenter`):**  
  Scheduled entirely on-device to deliver your daily capture prompt. No push notification servers or remote notification payloads are used.

---

## 3. Data Storage & Retention

- **Photos & Media:** Your photographs and optional BTS videos are stored in your device's Apple Photos library. If you uninstall Memoree, your photos remain safely in your Photos library.
- **App Data:** Metadata (such as streak counts, moment timestamps, and notification window preferences) is stored locally using Apple SwiftData and `UserDefaults`. This data is deleted if you remove the app from your device.

---

## 4. Third-Party Services & Subprocessors

Memoree does not use any third-party services, APIs, analytics providers, or advertising networks.

---

## 5. Children's Privacy

Memoree does not collect or solicit any personal information from anyone, including children under the age of 13.

---

## 6. Changes to This Privacy Policy

If we update this Privacy Policy, the revised policy will be posted with an updated "Last Updated" date.

---

## 7. Contact Us

If you have questions or feedback about this Privacy Policy, please contact us at:

- **Email:** support@memoree.app *(or your preferred support email)*  
- **GitHub:** https://github.com/javohirmx/memoree  
