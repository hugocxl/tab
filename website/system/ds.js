// Design system runtime: wires .ds-code copy buttons.
document.addEventListener('click', async event => {
  const button = event.target.closest('.ds-code button');
  if (!button) return;
  try {
    await navigator.clipboard.writeText(button.closest('.ds-code').querySelector('pre').textContent);
    button.textContent = 'Copied';
  } catch {
    button.textContent = 'Select to copy';
  }
  setTimeout(() => { button.textContent = 'Copy' }, 1600);
});
