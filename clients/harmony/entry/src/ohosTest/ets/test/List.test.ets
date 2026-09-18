import behaviorFixturesTest from './behavior/BehaviorFixturesTest';
import wireCasesTest from './behavior/WireCasesTest';
import unitTests from './unit/UnitTests.test';

export default function testsuite() {
  behaviorFixturesTest();
  wireCasesTest();
  unitTests();
}

