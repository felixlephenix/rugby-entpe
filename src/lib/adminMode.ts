const KEY = 'bs-admin-mode';

export function isAdminModeOn(): boolean {
  return localStorage.getItem(KEY) === 'on';
}

export function setAdminMode(on: boolean): void {
  localStorage.setItem(KEY, on ? 'on' : 'off');
  window.dispatchEvent(new Event('admin-mode-changed'));
}
