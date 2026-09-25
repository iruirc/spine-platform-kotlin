interface OrderRepository
class OrderRepositoryImpl @Inject constructor() : OrderRepository

@Qualifier @Retention(AnnotationRetention.BINARY) annotation class IoDispatcher

@Serializable data class OrderDetail(val orderId: String)
data class OrderDraft(val note: String)

interface AnalyticsSink
