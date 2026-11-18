// Follow the system appearance until the visitor picks one with a [data-ds-theme] button.
const preference = window.matchMedia('(prefers-color-scheme: dark)');
function applyTheme() {
  document.documentElement.dataset.theme = localStorage.getItem('ds-theme') || (preference.matches ? 'dark' : 'light');
}
applyTheme();
preference.addEventListener('change', applyTheme);

document.addEventListener('click', event => {
  if (!event.target.closest('[data-ds-theme]')) return;
  localStorage.setItem('ds-theme', document.documentElement.dataset.theme === 'light' ? 'dark' : 'light');
  applyTheme();
});
