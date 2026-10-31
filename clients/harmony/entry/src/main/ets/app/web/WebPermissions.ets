import { Permissions } from '@kit.AbilityKit';

export class WebPermissions {
  static required(resources: string[]): Permissions[] | null {
    if (resources.length === 0) { return null; }
    const permissions: Permissions[] = [];
    for (const resource of resources) {
      if (resource === ProtectedResourceType.VIDEO_CAPTURE) {
        permissions.push('ohos.permission.CAMERA');
      } else if (resource === ProtectedResourceType.AUDIO_CAPTURE) {
        permissions.push('ohos.permission.MICROPHONE');
      } else {
        return null;
      }
    }
    return permissions;
  }
}
