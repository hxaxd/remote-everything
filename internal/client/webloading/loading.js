(() => {
  const script = document.currentScript;
  const dark = script.dataset.scheme === 'dark';
  const cover = document.createElement('div');
  cover.dataset.remoteEverythingLoading = '';
  cover.setAttribute('role', 'progressbar');
  cover.setAttribute('aria-label', 'Loading');
  Object.assign(cover.style, {
    position: 'fixed', inset: '0', zIndex: '2147483647',
    background: dark ? '#1c1e24' : '#ffffff', display: 'grid', placeItems: 'center'
  });
  const ring = document.createElement('div');
  Object.assign(ring.style, {
    width: '28px', height: '28px', border: '3px solid transparent',
    borderTopColor: dark ? '#b6c4ff' : '#435ab4',
    borderRightColor: dark ? '#b6c4ff' : '#435ab4', borderRadius: '50%'
  });
  cover.attachShadow({mode: 'closed'}).append(ring);
  document.documentElement.append(cover);
  const animation = matchMedia('(prefers-reduced-motion: reduce)').matches ? null :
    ring.animate([{transform: 'rotate(0deg)'}, {transform: 'rotate(360deg)'}], {duration: 900, iterations: Infinity});
  let revealed = false;
  const reveal = () => {
    if (revealed) return;
    revealed = true;
    observer?.disconnect();
    requestAnimationFrame(() => requestAnimationFrame(() => {
      animation?.cancel();
      cover.remove();
    }));
  };
  let observer;
  if (performance.getEntriesByName('first-contentful-paint').length) reveal();
  else {
    observer = new PerformanceObserver(list => {
      if (list.getEntries().some(entry => entry.name === 'first-contentful-paint')) reveal();
    });
    observer.observe({type: 'paint', buffered: true});
  }
})();
