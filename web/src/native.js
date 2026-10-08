import { Capacitor } from '@capacitor/core';
import { App } from '@capacitor/app';
import { Share } from '@capacitor/share';

// True inside the iPhone and Android apps, false on the website.
export const isNative = Capacitor.isNativePlatform();

// The public website. Inside the apps window.location is capacitor://localhost
// or https://localhost, which is no use in a link sent to a friend, so the app
// build sets VITE_SITE_URL to the hosted site.
export const siteUrl = (import.meta.env.VITE_SITE_URL || (isNative ? '' : window.location.origin)).replace(/\/$/, '');

// Opens the phone's share sheet. Returns false when there isn't one, so the
// caller can fall back to copying the link.
export async function shareLink({ title, text, url }) {
  if (isNative) {
    await Share.share({ title, text, url, dialogTitle: title });
    return true;
  }
  if (!navigator.share) return false;
  await navigator.share({ title, text, url });
  return true;
}

// When an invite link opens the app (once the site's app links are set up),
// pass its ?join= code to the same handling the website uses.
export function onInviteOpened(handle) {
  if (!isNative) return;
  App.addListener('appUrlOpen', ({ url }) => {
    try {
      const code = new URL(url).searchParams.get('join');
      if (code) handle(code);
    } catch { /* not a link we know */ }
  });
}
