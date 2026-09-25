object BuildConfig { const val DEBUG = false }
interface TokenStore
lateinit var tokens: TokenStore
class AuthInterceptor(tokens: TokenStore) : okhttp3.Interceptor {
    override fun intercept(chain: okhttp3.Interceptor.Chain): okhttp3.Response = chain.proceed(chain.request())
}
class RetryInterceptor : okhttp3.Interceptor {
    override fun intercept(chain: okhttp3.Interceptor.Chain): okhttp3.Response = chain.proceed(chain.request())
}
