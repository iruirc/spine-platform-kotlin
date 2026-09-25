typealias ConcurrentHashMap<K, V> = java.util.concurrent.ConcurrentHashMap<K, V>
typealias DataSource = javax.sql.DataSource
typealias Executors = java.util.concurrent.Executors

object logger { fun error(e: Throwable, message: () -> String) {} }

interface OrderApi { suspend fun upload(order: Order) }

interface OrderRepository { suspend fun byId(id: String): Order? }
