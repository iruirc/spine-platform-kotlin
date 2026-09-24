# Demo

<!-- compile: jvm -->
```kotlin
val answer: Int = "forty-two"
```

<!-- compile: jvm-test -->
```kotlin
class AnswerTest {
    @Test
    fun answer_isFortyTwo() = assertEquals(42, answer)
}
```
