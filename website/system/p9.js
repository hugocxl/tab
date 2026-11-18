// Design system runtime: wires .p9-code copy buttons.
document.addEventListener('click', async event => {
  const button = event.target.closest('.p9-code button');
  if (!button) return;
  try {
    await navigator.clipboard.writeText(button.closest('.p9-code').querySelector('pre').textContent);
    button.textContent = 'Copied';
  } catch {
    button.textContent = 'Select to copy';
  }
  setTimeout(() => { button.textContent = 'Copy' }, 1600);
});
