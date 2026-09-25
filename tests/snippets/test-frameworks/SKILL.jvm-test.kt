class EmptyCartException : RuntimeException()

class Cart {
    companion object { val EMPTY = Cart() }
}

class FakeOrderRepository

class CheckoutService(repository: FakeOrderRepository) {
    fun submit(cart: Cart): Unit = throw EmptyCartException()
}
