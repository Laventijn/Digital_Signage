(() => {
  const image = document.getElementById('screen');
  const error = document.getElementById('error');
  let manifest = null;
  let index = 0;

  function showError() {
    image.hidden = true;
    error.hidden = false;
  }

  function showCurrent() {
    const entries = Array.isArray(manifest.images) ? manifest.images : [];
    if (entries.length === 0) {
      showError();
      return;
    }
    image.hidden = false;
    error.hidden = true;
    image.src = entries[index].file;
  }

  image.addEventListener('error', showError);

  fetch('manifest.json', { cache: 'no-store' })
    .then((response) => response.json())
    .then((data) => {
      manifest = data;
      showCurrent();
      if (manifest.mode === 'presentation' && manifest.images.length > 1) {
        const seconds = Math.max(1, Number(manifest.slide_seconds) || 5);
        window.setInterval(() => {
          index = (index + 1) % manifest.images.length;
          showCurrent();
        }, seconds * 1000);
      }
    })
    .catch(showError);
})();
