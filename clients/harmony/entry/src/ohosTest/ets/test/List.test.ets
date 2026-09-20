import behaviorFixturesTest from './behavior/BehaviorFixturesTest';
import wireCasesTest from './behavior/WireCasesTest';
import unitTests from './unit/UnitTests.test';
import storeTests from './unit/StoreTests.test';
import linkReportTests from './unit/LinkReport.test';
import webSessionsTests from './unit/WebSessions.test';

export default function testsuite() {
  behaviorFixturesTest();
  wireCasesTest();
  unitTests();
  storeTests();
  linkReportTests();
  webSessionsTests();
}
