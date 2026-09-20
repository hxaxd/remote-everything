// What a decoded body must mean, on top of the shape the strict decoder already
// read. The contract describes these rules in words — a connected catalog says
// ready, an offline one lists nothing, a state code says what its flags do, an
// activation is only ever the connected catalog — and they are enforced here, as
// pure functions the decoders call once the whole document is in hand. This is the
// middle of the three layers: Dto reads the shape, Wire checks the fields against
// each other, Strict holds the rules a single value must satisfy on its own.

import { JsonError } from '../json/Strict';
import { AppInfo } from '../model/Models';

/** Whether a state code says what its flags do: the four allowed combinations. */
export function appCodeMatchesFlags(code: string, enabled: boolean, running: boolean): boolean {
  if (code === 'ready') {
    return enabled && running;
  }
  if (code === 'starting') {
    return enabled && !running;
  }
  if (code === 'stopping') {
    return !enabled && running;
  }
  if (code === 'stopped') {
    return !enabled && !running;
  }
  return false;
}

/** One application row: its code and its enabled/running pair cannot disagree. */
export function validateAppDto(appId: string, code: string, enabled: boolean, running: boolean): void {
  if (!appCodeMatchesFlags(code, enabled, running)) {
    throw new JsonError(`the application ${appId} carries a code that contradicts enabled and running`);
  }
}

/** `{ok, computer_connected, code, apps}` as a whole: the catalog and its code agree. */
export function validateCatalog(computerConnected: boolean, code: string, apps: AppInfo[]): void {
  if (computerConnected !== (code === 'ready')) {
    throw new JsonError('the catalog code contradicts computer_connected');
  }
  if (!computerConnected && apps.length > 0) {
    throw new JsonError('an offline catalog still lists applications');
  }
  const seen: Set<string> = new Set<string>();
  for (const app of apps) {
    if (seen.has(app.id)) {
      throw new JsonError(`the catalog answer lists the application ${app.id} twice`);
    }
    seen.add(app.id);
  }
}

/** `{ok, action, computer_connected, enabled, running, code, app?, error_code?}`. */
export function validateControl(code: string, enabled: boolean, running: boolean,
  errorCode: string | null): void {
  // A state code says what its flags do; the other codes say nothing about them.
  if (code === 'ready' || code === 'starting' || code === 'stopping' || code === 'stopped') {
    if (!appCodeMatchesFlags(code, enabled, running)) {
      throw new JsonError('the control code contradicts enabled and running');
    }
  }
  if (errorCode !== null && errorCode !== 'stop_command_failed') {
    throw new JsonError('the control answer names an error this client does not know');
  }
}

/**
 * A 200 on the activation endpoint is the connected catalog, and nothing else: an
 * offline catalog in that answer is not an answer this client can act on, whatever
 * the catalog endpoint itself would make of it.
 */
export function validateActivation(computerConnected: boolean, code: string): void {
  if (!computerConnected || code !== 'ready') {
    throw new JsonError('an activation is not a connected catalog');
  }
}
