import behaviorFixturesTest from './behavior/BehaviorFixturesTest';
import wireCasesTest from './behavior/WireCasesTest';

export default function testsuite() {
  behaviorFixturesTest();
  wireCasesTest();
}
