@JvmInline value class Sku(val value: String)

data class PlaceOrderCommand(val sku: Sku, val quantity: Int)

class Reservation

class Order {
    companion object {
        fun from(command: PlaceOrderCommand, reserved: Reservation): Order = Order()
    }
}

interface OrderRepository {
    fun save(order: Order): Order
}

interface StockRepository {
    fun reserve(sku: Sku, quantity: Int): Reservation
}
