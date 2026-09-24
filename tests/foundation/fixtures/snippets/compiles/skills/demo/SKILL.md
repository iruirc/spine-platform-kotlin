# Demo

<!-- compile: jvm -->
```kotlin
@file:OptIn(ExperimentalCoroutinesApi::class)
package com.example.demo

import kotlinx.coroutines.ExperimentalCoroutinesApi

class Counter(private val clock: Clock) {
    private val ticks = MutableStateFlow(0)
    val value: StateFlow<Int> = ticks.asStateFlow()
    fun tick(): Instant { ticks.update { it + 1 }; return clock.now() }
}
```

<!-- compile: jvm-test -->
```kotlin
class CounterTest {
    @Test
    fun tick_incrementsValue() = runTest {
        val counter = Counter(Clock.System)
        counter.value.test {
            assertEquals(0, awaitItem())
            counter.tick()
            assertEquals(1, awaitItem())
        }
    }
}
```

<!-- compile: android -->
```kotlin
@HiltViewModel
class NotesViewModel @Inject constructor(private val dao: NoteDao) : ViewModel() {
    val notes: StateFlow<List<Note>> =
        dao.all().stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())
}

@Composable
fun NotesRoute(viewModel: NotesViewModel = hiltViewModel()) {
    val notes by viewModel.notes.collectAsStateWithLifecycle()
    LazyColumn(Modifier.padding(16.dp)) { items(notes) { Text(it.text) } }
}
```

<!-- compile: android-test -->
```kotlin
@RunWith(RobolectricTestRunner::class)
class NoteDaoTest {
    @Test
    fun all_startsEmpty() = runTest {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val db = Room.inMemoryDatabaseBuilder(context, NotesDatabase::class.java).build()
        db.notes().all().test { assertEquals(emptyList(), awaitItem()) }
    }
}
```

<!-- compile: spring -->
```kotlin
@RestController
@RequestMapping("/orders")
class OrderController(private val orders: OrderRepository) {
    @GetMapping("/{id}")
    fun get(@PathVariable id: Long): ResponseEntity<OrderEntity> =
        orders.findById(id).map { ResponseEntity.ok(it) }.orElse(ResponseEntity.notFound().build())
}

interface OrderRepository : JpaRepository<OrderEntity, Long>

@Entity
@Table(name = "orders")
class OrderEntity(@Id val id: Long = 0, val total: Long = 0)
```

<!-- compile: spring-test -->
```kotlin
@WebMvcTest(OrderController::class)
class OrderControllerTest(@Autowired private val mvc: MockMvc) {
    @MockitoBean
    lateinit var orders: OrderRepository

    @Test
    fun get_unknownId_returns404() {
        mvc.get("/orders/1").andExpect { status { isNotFound() } }
    }
}
```

<!-- compile: ktor -->
```kotlin
object Users : Table("users") {
    val id = long("id")
    val name = varchar("name", 100)
    override val primaryKey = PrimaryKey(id)
}

fun Application.module() {
    install(ContentNegotiation) { json() }
    install(Koin) { modules(module { single { Database.connect("jdbc:h2:mem:") } }) }
    routing {
        get("/users/{id}") {
            val id = call.parameters["id"]?.toLongOrNull() ?: return@get call.respond(HttpStatusCode.BadRequest)
            val name = transaction { Users.selectAll().where { Users.id eq id }.singleOrNull()?.get(Users.name) }
            if (name == null) call.respond(HttpStatusCode.NotFound) else call.respondText(name)
        }
    }
}
```

<!-- compile: ktor-test -->
```kotlin
class ModuleTest {
    @Test
    fun unknownId_isBadRequest() = testApplication {
        application { module() }
        assertEquals(HttpStatusCode.BadRequest, client.get("/users/x").status)
    }
}
```

The same unit, later in the file:

<!-- compile: jvm -->
```kotlin
import kotlinx.coroutines.ExperimentalCoroutinesApi

fun Counter.tickTwice(): Instant { tick(); return tick() }
```

```kotlin
val notMarked: Int = "a block without a marker is not compiled"
```
