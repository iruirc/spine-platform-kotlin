interface SessionStorage {
    suspend fun load(): BearerTokens?
    suspend fun save(tokens: BearerTokens)
}
@Serializable data class RefreshRequest(val refreshToken: String)
@Serializable data class TokenPair(val access: String, val refresh: String)
val isDebug = false
lateinit var session: SessionStorage
