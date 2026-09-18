// What each gateway last said about its nodes.
//
// This is a cache and only a cache: it exists so a cold start shows the list that
// was there last time instead of an empty screen, and every refresh replaces it
// whole with what the gateway just answered. A node is never added to or removed
// from it locally — a node appears because a gateway said so and disappears for the
// same reason (ui-contract §2/S1, architecture §4).

import { JsonReader } from '../json/Strict';
import { CachedNodes, GatewayPath, Node } from '../model/Models';
import { Sandbox } from './Sandbox';

const SCHEMA = 1;
const FINGERPRINT = new RegExp('^[a-f0-9]{64}$');

function decodeIdentityRef(reader: JsonReader): GatewayPath {
  reader.rejectUnknown(['origin', 'private']);
  const origin: string = reader.string('origin');
  const isPrivate: boolean = reader.bool('private');
  return new GatewayPath(origin, '', null, null, isPrivate, null);
}

function decodeNode(reader: JsonReader): Node {
  reader.rejectUnknown(['id', 'name', 'paths']);
  const id: string = reader.pattern('id', FINGERPRINT);
  const name: string = reader.string('name');
  const paths: GatewayPath[] = [];
  for (const entry of reader.array('paths')) {
    paths.push(decodeIdentityRef(JsonReader.of(entry, 'nodes[].paths[]')));
  }
  return new Node(id, name, paths);
}

export class NodeCacheStore {
  private file(origin: string): string {
    return `cache/nodes/${Sandbox.originKey(origin)}.json`;
  }

  read(origin: string): CachedNodes | null {
    const text: string | null = Sandbox.readText(this.file(origin));
    if (text === null) {
      return null;
    }
    try {
      const reader: JsonReader = JsonReader.parse(text, 'nodes cache');
      reader.rejectUnknown(['schema', 'origin', 'fetched_at', 'nodes']);
      if (reader.number('schema') !== SCHEMA || reader.string('origin') !== origin) {
        return null;
      }
      const fetchedAt: number = reader.number('fetched_at');
      const nodes: Node[] = [];
      for (const entry of reader.array('nodes')) {
        nodes.push(decodeNode(JsonReader.of(entry, 'nodes cache')));
      }
      return new CachedNodes(origin, nodes, fetchedAt);
    } catch (error) {
      return null;
    }
  }

  /** Replaces one gateway's cached answer with the one just received. */
  write(origin: string, nodes: Node[], fetchedAt: number): void {
    Sandbox.ensureDirectory('cache/nodes');
    const encoded: string[] = [];
    for (const node of nodes) {
      encoded.push(this.encodeNode(node));
    }
    const document: string = `{"schema":${SCHEMA},"origin":${JSON.stringify(origin)},` +
      `"fetched_at":${fetchedAt},"nodes":[${encoded.join(',')}]}`;
    Sandbox.writeAtomic(this.file(origin), document);
  }

  remove(origin: string): void {
    Sandbox.removeWithTemporary(this.file(origin));
  }

  private encodeNode(node: Node): string {
    const paths: string[] = [];
    for (const path of node.paths) {
      paths.push(`{"origin":${JSON.stringify(path.origin)},"private":${path.isPrivate}}`);
    }
    return `{"id":${JSON.stringify(node.id)},"name":${JSON.stringify(node.name)},"paths":[${paths.join(',')}]}`;
  }
}
