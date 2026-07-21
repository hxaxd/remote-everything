import gatewaySecurityPolicyTest from './ets/GatewaySecurityPolicy.test';
import remoteApiTest from './ets/RemoteApi.test';
import setupParserTest from './ets/SetupParser.test';
import setupTransactionTest from './ets/SetupTransaction.test';

export default function testsuite(): void {
  gatewaySecurityPolicyTest();
  remoteApiTest();
  setupParserTest();
  setupTransactionTest();
}
