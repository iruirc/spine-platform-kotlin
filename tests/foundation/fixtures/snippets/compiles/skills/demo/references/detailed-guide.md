# Demo — detailed guide

<!-- compile: kmp -->
```kotlin
@Serializable
data object Home

class HomeViewModel(private val greeting: String) : ViewModel() {
    val state: StateFlow<String> = MutableStateFlow(greeting)
}

val homeModule = module { viewModelOf(::HomeViewModel) }

@Composable
fun App() {
    val nav = rememberNavController()
    NavHost(nav, startDestination = Home) {
        composable<Home> {
            val vm = koinViewModel<HomeViewModel>()
            Text(vm.state.collectAsState().value)
        }
    }
}
```

<!-- compile: kmp-test -->
```kotlin
class HomeViewModelTest {
    @Test
    fun state_startsWithGreeting() = runTest {
        HomeViewModel("hi").state.test { assertEquals("hi", awaitItem()) }
    }
}
```

<!-- compile: net -->
```kotlin
import com.example.api.generated.api.OrdersApi as Generated

internal class OrderNames(private val api: Generated) {
    suspend fun first(): String? = api.listOrders(cursor = null).body()?.items?.firstOrNull()?.id
}

class AuthInterceptor(private val token: () -> String) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response =
        chain.proceed(chain.request().newBuilder().header("Authorization", "Bearer ${token()}").build())
}

fun retrofit(client: OkHttpClient): Retrofit = Retrofit.Builder()
    .baseUrl("https://example.com/")
    .client(client)
    .addConverterFactory(Json.asConverterFactory("application/json".toMediaType()))
    .build()
```

<!-- compile: net-test -->
```kotlin
class AuthInterceptorTest {
    @Test
    fun intercept_addsBearer() {
        MockWebServer().use { server ->
            server.start()
            val client = OkHttpClient.Builder().addInterceptor(AuthInterceptor { "t" }).build()
            client.newCall(Request.Builder().url(server.url("/")).build()).execute().close()
            assertEquals("Bearer t", server.takeRequest().headers["Authorization"])
        }
    }
}
```

<!-- compile: catalog -->
```toml
[versions]
kotlin = "2.4.20"

[plugins]
ksp = { id = "com.google.devtools.ksp", version.ref = "ksp" }
```
