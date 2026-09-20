// The report a person copies out of a connection that will not answer: what a
// failure is classified as, and what the report says line by line. No gateway and
// no device are involved — the input is built by hand and `say` returns the key a
// line came from, so an assertion reads as the report's shape.

import { describe, expect, it } from '@ohos/hypium';
import { ClientError, ErrorCode, NetworkError, WireProtocolError } from '../../../../main/ets/core/model/Errors';
import {
  LinkAttempt,
  LinkReportInput,
  LinkTrouble,
  TroubleKind,
  buildLinkReport,
  classifyFailure
} from '../../../../main/ets/core/diag/LinkReport';

const AT: number = 1758000000000;
const BEFORE: number = 1757999940000;

/** The words, as the keys they came from. */
function say(key: string, arg: string | null): string {
  return arg === null ? key : `${key}=${arg}`;
}

function stamp(at: number): string {
  return `t${at}`;
}

function input(trouble: LinkTrouble, attempts: LinkAttempt[], machines: string[]): LinkReportInput {
  return new LinkReportInput('app.name', '3.5.0 (28)', '1', 'HarmonyOS 6.1.1 (API 24) · MLR-AL00',
    'https://gw.example.com', 'PLG110', 'wifi · internet ✓ · vpn ✗', machines, trouble, attempts, stamp);
}

export default function linkReportTests() {
  describe('LinkReportTests', () => {
    it('LinkReport_classifies_a_refusal_with_its_code', 0, () => {
      const failure = classifyFailure(ClientError.refusal(ErrorCode.Unauthorized, 401), false);
      expect(failure.kind).assertEqual(TroubleKind.Refused);
      expect(failure.code).assertEqual('unauthorized');
      expect(failure.httpStatus).assertEqual(401);
    });

    it('LinkReport_offline_is_said_before_anything_else', 0, () => {
      expect(classifyFailure(new NetworkError('connect failed'), true).kind).assertEqual(TroubleKind.NoNetwork);
      expect(classifyFailure(ClientError.refusal(ErrorCode.Unauthorized, 401), true).kind)
        .assertEqual(TroubleKind.NoNetwork);
    });

    it('LinkReport_a_request_that_answered_nothing_is_unreachable', 0, () => {
      expect(classifyFailure(ClientError.transport('the request was cancelled'), false).kind)
        .assertEqual(TroubleKind.Unreachable);
      expect(classifyFailure(new NetworkError('connect failed'), false).kind).assertEqual(TroubleKind.Unreachable);
    });

    it('LinkReport_an_answer_this_client_cannot_read_is_its_own_kind', 0, () => {
      expect(classifyFailure(ClientError.client('the nodes answer is not one this client reads'), false).kind)
        .assertEqual(TroubleKind.BadAnswer);
      expect(classifyFailure(new WireProtocolError('the answer is not the JSON this client reads'), false).kind)
        .assertEqual(TroubleKind.BadAnswer);
    });

    it('LinkReport_names_the_failure_it_carries', 0, () => {
      const failure = classifyFailure(ClientError.transport('the gateway did not present the certificate'), false);
      expect(failure.detail).assertEqual('ClientError: the gateway did not present the certificate');
      expect(classifyFailure(new Error('something else'), false).kind).assertEqual(TroubleKind.Unknown);
    });

    it('LinkReport_says_one_line_per_fact', 0, () => {
      const trouble = new LinkTrouble(TroubleKind.Refused, AT, AT - 5000, 3, 'unauthorized', 401,
        'ClientError: refused: unauthorized', BEFORE);
      const report: string = buildLinkReport(
        input(trouble, [new LinkAttempt(AT, TroubleKind.Refused)], ['Windows-PC 本地 ✓ 12ms 隧道 ✗']), say);
      const lines: string[] = report.split('\n');
      expect(lines[0]).assertEqual('app.name · diag.title');
      expect(lines[1]).assertEqual('diag.client 3.5.0 (28) · settings.protocol_version 1');
      expect(lines[2]).assertEqual('diag.system HarmonyOS 6.1.1 (API 24) · MLR-AL00');
      expect(lines[3]).assertEqual('diag.connection https://gw.example.com · diag.device_name PLG110');
      expect(lines[4]).assertEqual(`diag.state diag.cause_refused · diag.failures=3 · diag.since=t${AT - 5000}` +
        ` · diag.last_answer=t${BEFORE}`);
      expect(lines[5]).assertEqual('diag.cause ClientError: refused: unauthorized · HTTP 401 · unauthorized');
      expect(lines[6]).assertEqual('diag.network wifi · internet ✓ · vpn ✗');
      expect(lines[7]).assertEqual('diag.machines Windows-PC 本地 ✓ 12ms 隧道 ✗');
      expect(lines[8]).assertEqual(`diag.attempts t${AT} diag.cause_refused`);
    });

    it('LinkReport_says_nothing_it_does_not_know', 0, () => {
      const trouble = new LinkTrouble(TroubleKind.NoNetwork, AT, AT, 1, null, null,
        'NetworkError: connect failed', null);
      const report: string = buildLinkReport(input(trouble, [], []), say);
      expect(report.includes('diag.last_answer')).assertFalse();
      expect(report.includes('diag.attempts')).assertFalse();
      expect(report.includes('diag.machines')).assertFalse();
      expect(report.split('\n').length).assertEqual(7);
    });
  });
}
