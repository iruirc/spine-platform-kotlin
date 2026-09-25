typealias IOException = java.io.IOException

fun interface SyncOrders { suspend operator fun invoke() }
