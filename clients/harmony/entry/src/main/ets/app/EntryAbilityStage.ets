// The module's stage: what the framework creates once, before any ability exists.
//
// It has nothing to do — every part of this app lives in the ability. But the
// module entry has to be a stage and not an ability: point it at the ability's
// file and the framework instantiates that class as the stage, calls its lifecycle
// with no arguments, and the ability's `onCreate(want, …)` reads a want that was
// never passed. (In practice: `Cannot read property uri of undefined` at launch.)

import { AbilityStage } from '@kit.AbilityKit';

export default class EntryAbilityStage extends AbilityStage {
  onCreate(): void {
  }
}
