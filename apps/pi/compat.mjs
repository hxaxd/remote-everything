const missingModeElement = 'document.getElementById("mode-pi").classList.add("active");';
const optionalModeElement = 'document.getElementById("mode-pi")?.classList.add("active");';

/** Reproduce wgnr-pi 1.5.2's session key so the launcher can recognize only that broken path component. */
export function upstreamSessionKey(cwd) {
  return `--${cwd.replace(/^\//, "").replace(/\//g, "-")}--`;
}

/** Match Pi Coding Agent's cross-platform session directory encoding. */
export function piSessionKey(cwd) {
  return `--${cwd.replace(/^[/\\]/, "").replace(/[/\\:]/g, "-")}--`;
}

/** Repair the stale mode selector without otherwise changing the pinned third-party page. */
export function patchIndexHtml(source) {
  const occurrences = source.split(missingModeElement).length - 1;
  if (occurrences !== 1) {
    throw new Error(`expected one stale mode-pi selector, found ${occurrences}`);
  }
  return source.replace(missingModeElement, optionalModeElement);
}
