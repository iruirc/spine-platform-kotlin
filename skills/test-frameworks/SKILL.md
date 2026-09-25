---
name: test-frameworks
description: "Use when writing a Kotlin test or reading a failing one — one section per value of the manifest's `tests` axis (JUnit5, JUnit4, Kotest): how a test is declared so the runner collects it, how it asserts, its lifecycle hooks, parameterization, asynchronous tests, how its failure reads in the report, and what the build needs to run it. Plus the surfaces that force a framework whatever the axis says, and how each value replaces `Dispatchers.Main`. Which value a given file takes is `spine-toolkit:test-authoring`'s decision, not this skill's."
---

# Test Frameworks

`spine-toolkit:test-authoring` picks the framework for the file being written. This skill says what
that pick means in code. Read the one section named after the value, not all three.

> **Related skills:**
> - `pkg-kmp-source-sets` — which source set owns a test, and what `commonTest` can compile at all
> - `concurrency-coroutines` — `runTest` and the test scheduler, which read the same under all three values
> - `persistence-migrations` — fixture-based migration tests, written in whichever value the axis names
> - `di-spring` — the Spring test slices whose annotations each value wires up differently

## When to Use

- A test file is about to be written, extended or read, and the project's `- Tests:` value is not
  the one the last file used
- A failing run has to be read out of `build/test-results/` and the report shape depends on the value
- A build needs the dependency and the `Test` task wiring that makes the chosen value run at all
- The surface under test (a Compose rule, Robolectric, a device, `commonTest`) may be forcing a
  framework the axis did not choose
- The code under test launches on `Dispatchers.Main` — a ViewModel's `viewModelScope` — and the test
  has to replace it

Not for deciding which value applies — that is `spine-toolkit:test-authoring`. Not for what a good
test is (structure, naming, what may be replaced by a double) — that is the tester agent.

## Forced by surface

Where only one framework can drive a surface, it wins over the axis value.

| Surface | Framework | Why |
|---|---|---|
| A Compose UI test (`createComposeRule()`) | JUnit4; on a device, JUnit5 too once the module applies `de.mannodermaus.android-junit` | the rule is a JUnit4 `TestRule`, and JUnit5 has no `@Rule`; that plugin's `createComposeExtension()` is the JUnit5 form |
| A Robolectric test | JUnit4 | `RobolectricTestRunner` is a JUnit4 runner |
| A test in `androidInstrumentedTest` | JUnit4, or JUnit5 once the module applies `de.mannodermaus.android-junit` | the device runner is `AndroidJUnitRunner`, which reaches JUnit5 only through that plugin, and only on devices of API 26+ |
| A test in `commonTest` of a KMP module | `kotlin.test`, or Kotest with its multiplatform engine | `org.junit` and `org.junit.jupiter` are JVM-only artifacts and do not resolve in common code |
| A test that boots Quarkus (`@QuarkusTest`) | JUnit5 | the Quarkus test support is a JUnit 5 extension and there is no other |
| Anything else | the axis value | — |

In `commonTest` the test is written against `kotlin.test` — `@Test`, `assertEquals`,
`assertFailsWith`, `@BeforeTest`/`@AfterTest`. On the JVM and Android targets those annotations are
executed by whatever the axis value puts on the classpath, so the axis still decides what runs them.
Kotest compiles in `commonTest` only where the module applies the `io.kotest` Gradle plugin with
`com.google.devtools.ksp` and has `kotest-framework-engine` in the common test source set.

One module may hold two frameworks at once: the JUnit Platform runs JUnit5, Kotest and — through
`junit-vintage-engine` — JUnit4 in a single pass. That is why a test added to an existing file keeps
that file's framework instead of the module's.

## JUnit5

### Declaration

`@Test` from `org.junit.jupiter.api` on a method of a plain class: no runner, no base class, no
annotation on the class itself. A fresh instance is created per test method, so a property of the
class does not leak between tests; anything in a `companion object` does.

<!-- compile: jvm-test -->
```kotlin
class CheckoutServiceTest {
    @Test
    fun submit_emptyCart_throwsEmptyCartException() {
        // Arrange
        val service = CheckoutService(FakeOrderRepository())

        // Act & Assert
        assertThrows<EmptyCartException> { service.submit(Cart.EMPTY) }
    }
}
```

The method name is the test's name. A backticked sentence name is legal Kotlin and compiles, but it
loses the `method_condition_expected` shape `spine-toolkit:test-authoring` asks for — put the
sentence in `@DisplayName` instead and keep the identifier.

### Assertions

`kotlin.test` (`assertEquals`, `assertTrue`, `assertNull`, `assertFailsWith<T> { }`) or AssertJ
(`assertThat(x).isEqualTo(y)`), whichever the project already imports — never both in one module.
`org.junit.jupiter.api.assertThrows<T> { }` returns the exception, so its message can be asserted.
`assertAll({ … }, { … })` takes one lambda per check and reports every failure among them — one
`MultipleFailuresError` — instead of stopping at the first.

### Lifecycle

`@BeforeEach` / `@AfterEach` around every test method. `@BeforeAll` / `@AfterAll` run once per class
and must be `@JvmStatic` members of a `companion object`, unless the class carries
`@TestInstance(Lifecycle.PER_CLASS)`. `@TempDir` injects a directory that is deleted afterwards.
A `@Nested` inner class inherits the outer class's hooks.

### Parameterization

`@ParameterizedTest` with `@ValueSource`, `@CsvSource`, `@EnumSource` or `@MethodSource("cases")` —
the source method is a `@JvmStatic` member of a `companion object` returning a `Stream`, a `List` or
an `Iterable`. Each case is reported as its own test, which is the point: a loop inside one `@Test`
reports one failure for the whole set.

### Async

A test body that suspends is wrapped in `runTest { }` from `kotlinx-coroutines-test`; JUnit 5 does
not call a `suspend fun` test method itself. `@Timeout(5)` bounds a test that may hang. `Dispatchers.Main`
is replaced by an extension — Main Dispatcher in Tests, below.

### Failure output

Gradle writes JUnit XML to `build/test-results/test/TEST-<fully.qualified.ClassName>.xml`; Maven to
`target/surefire-reports/`. A failure is a `<failure>` element inside its `<testcase>`:

```xml
<testcase name="submit_emptyCart_throwsEmptyCartException()" classname="com.example.CheckoutServiceTest" time="0.012">
  <failure message="expected: &lt;2&gt; but was: &lt;1&gt;" type="org.opentest4j.AssertionFailedError">org.opentest4j.AssertionFailedError: expected: &lt;2&gt; but was: &lt;1&gt;
	at com.example.CheckoutServiceTest.submit_emptyCart_throwsEmptyCartException(CheckoutServiceTest.kt:21)</failure>
</testcase>
```

The `name` carries the parentheses, and a parameterized case reads `[1] a, b`. The `type` names the
assertion error class — `org.opentest4j.AssertionFailedError` for `kotlin.test` and JUnit 5's own
assertions.

### Setup

`testImplementation("org.junit.jupiter:junit-jupiter")`,
`testRuntimeOnly("org.junit.platform:junit-platform-launcher")`, and
`tasks.withType<Test>().configureEach { useJUnitPlatform() }`. On Android, unit tests need the
same two dependencies and `testOptions { unitTests.all { it.useJUnitPlatform() } }`, or the
`de.mannodermaus.android-junit` plugin, which does the wiring for every variant; the plugin is also
what runs JUnit5 in `androidTest` (`## Forced by surface`).

JUnit 6 keeps the `org.junit.jupiter` API of this section: it needs Java 17, deprecates
`junit-vintage-engine`, and runs a `suspend fun` test method itself — without a virtual clock, so
`runTest` stays wherever time is advanced.

## JUnit4

### Declaration

`@Test` from `org.junit` on a method of a class with a no-argument constructor, and `@RunWith(...)`
where a runner is required — `RobolectricTestRunner`, `AndroidJUnit4`, `Parameterized`. A fresh
instance per test method, as in JUnit5.

<!-- compile: android-test -->
```kotlin
@RunWith(RobolectricTestRunner::class)
class PreferencesManagerTest {
    @Test
    fun saveTheme_darkMode_persistsSelection() {
        val manager = PreferencesManager(ApplicationProvider.getApplicationContext())

        manager.saveTheme(Theme.DARK)

        assertEquals(Theme.DARK, manager.getTheme())
    }
}
```

One class has one runner. Two `@RunWith`s cannot be combined — see `### Parameterization`.

### Assertions

`org.junit.Assert.assertEquals` / `assertTrue` / `assertNull`, whose argument order is
`(expected, actual)`, or `kotlin.test`, whose order is the same but whose failures come out of the
JUnit4 classes anyway. `assertThrows(EmptyCartException::class.java) { }` returns the exception;
`@Test(expected = …)` also exists and hides *where* the throw happened, so prefer `assertThrows`.

### Lifecycle

`@Before` / `@After` around every test method. `@BeforeClass` / `@AfterClass` run once per class and
must be `@JvmStatic` members of a `companion object`. Everything else is a rule: `@get:Rule` for a
per-test rule (`TemporaryFolder`, `InstantTaskExecutorRule`, `createComposeRule()`), `@get:ClassRule`
for a per-class one. In Kotlin the `@get:` prefix is not optional — a rule annotated `@Rule` on the
property lands on the private backing field, and JUnit4 rejects the class before any test runs:
`InvalidTestClassError: … The @Rule 'tmp' must be public.`

### Parameterization

`@RunWith(Parameterized::class)` with constructor parameters and a `@JvmStatic
@Parameterized.Parameters` method returning the cases. It occupies the class's only runner slot, so
it cannot be combined with Robolectric's — that combination is `ParameterizedRobolectricTestRunner`.

### Async

`runTest { }`, as in JUnit5. `@Test(timeout = …)` bounds a test that may hang. `Dispatchers.Main` is
replaced by a rule — Main Dispatcher in Tests, below.

### Failure output

The same report path and shape as JUnit5 — `build/test-results/test/TEST-<fqcn>.xml`. Two
differences a reader depends on: the `<testcase name>` has no parentheses, and the `type` is
`java.lang.AssertionError` or `org.junit.ComparisonFailure`, never opentest4j.

### Setup

`testImplementation("junit:junit:4.13.2")` and the default `Test` task — no `useJUnitPlatform()`.
In a module that runs the JUnit Platform for something else, JUnit4 tests still run when
`testRuntimeOnly("org.junit.vintage:junit-vintage-engine")` is present. On Android this is the
dependency a fresh module already has, plus `androidx.test.ext:junit` for the instrumented set.

## Kotest

### Declaration

A spec is a class extending a style — `FunSpec`, `StringSpec`, `BehaviorSpec`, `DescribeSpec`,
`ShouldSpec` — and its tests are registered in the constructor lambda or an `init { }` block. The
test's name is the string, not a method name, so the `method_condition_expected` parts go into the
string. Match the style the project already uses; a second style in the same module is noise.

<!-- compile: jvm-test -->
```kotlin
import io.kotest.assertions.throwables.shouldThrow

class CheckoutServiceSpec : FunSpec({
    test("submit with an empty cart throws EmptyCartException") {
        val service = CheckoutService(FakeOrderRepository())

        shouldThrow<EmptyCartException> { service.submit(Cart.EMPTY) }
    }
})
```

The default `IsolationMode` is `SingleInstance`: the spec is instantiated once and every test shares
what the spec body declared. `InstancePerRoot` gives each root test its own instance
(`InstancePerTest` and `InstancePerLeaf` are deprecated in Kotest 6). State declared in the spec body
under the default mode is shared state, not fresh state.

### Assertions

`shouldBe`, `shouldNotBe`, `shouldContain`, `shouldBeInstanceOf<T>()`, `shouldThrow<T> { }` from
`kotest-assertions-core`; `kotlin.test` also works. `withClue("...") { }` labels a failure,
`assertSoftly { }` collects several instead of stopping at the first.

### Lifecycle

`beforeTest` / `afterTest`, `beforeContainer` / `afterContainer` and `beforeSpec` / `afterSpec`,
declared inside the spec body. A shared hook is an extension, registered by
`override val extensions = listOf(MyExtension)` — a `val` in Kotest 6, where 5.x had
`override fun extensions()` — or by `@ApplyExtension(MyExtension::class)` on the spec. Kotest 6
removed autoscanning: an extension nobody registers does not run.

### Parameterization

`withData(...)` from `io.kotest.datatest` inside a container — each datum becomes its own test, and
`withData(nameFn = { … })` names them. It is part of core from Kotest 6; `kotest-framework-data` is
no longer a dependency, while 4.x-era table testing now needs `kotest-assertions-table`. `checkAll`
from `kotest-property` for property tests, only where the invariant is genuinely universal.

### Async

A test body is already a suspending function: `delay` and `await` work with no wrapper. `runTest` is
still what installs the virtual clock of `kotlinx-coroutines-test` when time has to be advanced.
`eventually(5.seconds) { }` from `kotest-assertions-core` polls until a condition holds instead of
sleeping once. A per-test timeout is `test("…").config(timeout = 5.seconds) { }`. `Dispatchers.Main`
is replaced by a listener — Main Dispatcher in Tests, below.

### Failure output

The same JUnit XML as the other two: Kotest runs on the JUnit Platform, so Gradle writes
`build/test-results/test/TEST-<spec fqcn>.xml`. What differs is what a `<testcase name>` holds — the
leaf test's own string under the `classname` of the spec, with no enclosing container: a `withData`
case inside `context("doubling")` is `name="2"`, and only the console prints `doubling > 2`. A
failure is `<failure type="org.opentest4j.AssertionFailedError">` on the JVM, and the message is the
matcher's (`expected:<2> but was:<1>`). A validator reading the XML needs no second parser for this
value, but it cannot tell two same-named cases in different containers apart.

### Setup

`testImplementation("io.kotest:kotest-runner-junit5:<version>")` with
`tasks.withType<Test>().configureEach { useJUnitPlatform() }`; matchers and property testing are
separate artifacts (`kotest-assertions-core`, `kotest-property`). In a KMP module: the `io.kotest`
Gradle plugin with `com.google.devtools.ksp`, and `kotest-framework-engine` in `commonTest`. On
Android: `useJUnitPlatform()` in `testOptions` for unit tests, and for an instrumented test
`kotest-runner-junit4` with `@RunWith(KotestTestRunner::class)`.

## Main Dispatcher in Tests

`viewModelScope`, and anything else that launches on `Dispatchers.Main`, takes no dispatcher
parameter, so the test replaces `Main` itself: `Dispatchers.setMain(StandardTestDispatcher())` before
each test, `Dispatchers.resetMain()` after it. `runTest` then takes its scheduler from that `Main`, so
`advanceUntilIdle()` reaches the ViewModel's work. The call goes into the framework's own hook, and a
hook of another framework compiles and never runs — a JUnit4 rule in a JUnit5 class replaces nothing.

| Value | Mechanism | Applied by |
|---|---|---|
| JUnit5 | an extension | `@ExtendWith(MainDispatcherExtension::class)` on the class; `@JvmField @RegisterExtension val main = MainDispatcherExtension()` when the test needs `main.dispatcher` |
| JUnit4 | a rule | `@get:Rule val main = MainDispatcherRule()` |
| Kotest | a listener | `extension(MainDispatcherListener())` in the spec body |
| `kotlin.test` in `commonTest` | the hooks | `@BeforeTest` / `@AfterTest` calling `Dispatchers.setMain` / `resetMain`, which are multiplatform |

<!-- compile: jvm-test -->
```kotlin
import org.junit.jupiter.api.extension.AfterEachCallback
import org.junit.jupiter.api.extension.BeforeEachCallback
import org.junit.jupiter.api.extension.ExtensionContext

class MainDispatcherExtension(
    val dispatcher: TestDispatcher = StandardTestDispatcher(),
) : BeforeEachCallback, AfterEachCallback {
    override fun beforeEach(context: ExtensionContext) = Dispatchers.setMain(dispatcher)
    override fun afterEach(context: ExtensionContext) = Dispatchers.resetMain()
}
```

<!-- compile: jvm-test -->
```kotlin
import org.junit.rules.TestWatcher
import org.junit.runner.Description

class MainDispatcherRule(
    val dispatcher: TestDispatcher = StandardTestDispatcher(),
) : TestWatcher() {
    override fun starting(description: Description) = Dispatchers.setMain(dispatcher)
    override fun finished(description: Description) = Dispatchers.resetMain()
}
```

<!-- compile: jvm-test -->
```kotlin
import io.kotest.core.listeners.AfterTestListener
import io.kotest.core.listeners.BeforeTestListener
import io.kotest.core.test.TestCase
import io.kotest.engine.test.TestResult

class MainDispatcherListener(
    val dispatcher: TestDispatcher = StandardTestDispatcher(),
) : BeforeTestListener, AfterTestListener {
    override suspend fun beforeTest(testCase: TestCase) = Dispatchers.setMain(dispatcher)
    override suspend fun afterTest(testCase: TestCase, result: TestResult) = Dispatchers.resetMain()
}

class OrdersViewModelSpec : FunSpec({
    extension(MainDispatcherListener())
})
```

## Common Mistakes

- **`@BeforeEach` in a class a JUnit4 runner collects.** It compiles wherever jupiter is on the
  classpath and is never called: the test runs with nothing arranged, and the failure reads like a
  bug in production code.
- **`@Rule` without `@get:`.** The annotation lands on a private backing field and the whole class
  fails as `initializationError` with "The @Rule 'tmp' must be public" — one red line where the
  class's tests should be, none of them run.
- **A JUnit import in `commonTest`.** It does not resolve, and the fix is not adding a dependency —
  it is `kotlin.test`, or Kotest with its multiplatform engine.
- **`@BeforeAll` on a non-static member** without `@TestInstance(Lifecycle.PER_CLASS)` — JUnit 5
  refuses the class at startup, so an unrelated green run turns red at the wrong place.
- **State in a Kotest spec body under the default `SingleInstance`.** It is shared by every test in
  the spec, and the suite passes or fails by order.
- **Adding the other framework's dependency to make one file compile.** That is a second framework
  in the module, chosen by nobody: the file's framework is `spine-toolkit:test-authoring`'s call.
