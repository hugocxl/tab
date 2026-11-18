// Follow the system appearance until the visitor picks one with a [data-p9-theme] button.
const preference = window.matchMedia('(prefers-color-scheme: dark)');
function applyTheme() {
  document.documentElement.dataset.theme = localStorage.getItem('p9-theme') || (preference.matches ? 'dark' : 'light');
}
applyTheme();
preference.addEventListener('change', applyTheme);

document.addEventListener('click', event => {
  if (!event.target.closest('[data-p9-theme]')) return;
  localStorage.setItem('p9-theme', document.documentElement.dataset.theme === 'light' ? 'dark' : 'light');
  applyTheme();
});
