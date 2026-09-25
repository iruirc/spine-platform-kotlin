object BuildConfig { const val DEBUG = false }
lateinit var cacheDir: java.io.File
lateinit var appScope: kotlinx.coroutines.CoroutineScope
@kotlinx.serialization.Serializable data class Token(val access: String, val refreshToken: String)
class TokenStore(scope: kotlinx.coroutines.CoroutineScope, auth: AuthApi) {
    val current: Token get() = TODO()
    suspend fun refresh(seen: Token): Token = TODO()
}
@kotlinx.serialization.Serializable data class OrderDraftDto(val lines: List<String>)
class HttpStatusException(val code: Int) : java.io.IOException("HTTP $code")
